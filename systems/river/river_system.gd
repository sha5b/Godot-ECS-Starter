class_name RiverSystem
extends BaseSystem

## Continuous river surface renderer.
## TerrainSystem still owns river tracing + carving, but rendering is driven by
## per-chunk river render paths so the visible water becomes a connected
## downstream surface instead of isolated stepped tiles.

var _config: RiverConfig

## chunk_coord → MeshInstance3D
var _chunk_meshes: Dictionary = {}

## chunk_coord → PackedFloat32Array (cached surface heightmaps)
var _chunk_heightmaps: Dictionary = {}

## chunk_coord → Array of sampled ribbon paths used for rendering / underwater tests
var _chunk_sampled_paths: Dictionary = {}

var _chunk_materials: Dictionary = {}

var _river_material: ShaderMaterial


func _initialize() -> void:
	system_name = &"RiverSystem"
	priority = 3

	_config = _find_child_of_type(RiverConfig)
	if not _config:
		push_warning("[RiverSystem] No RiverConfig child found — using defaults")
		_config = RiverConfig.new()

	_setup_material()


func _register_signals() -> void:
	SystemBus.terrain_chunk_ready.connect(_on_terrain_chunk_ready)
	SystemBus.chunk_unload_requested.connect(_on_chunk_unload_requested)


func _setup_material() -> void:
	var shader := Shader.new()
	shader.code = _get_river_shader_code()
	_river_material = ShaderMaterial.new()
	_river_material.shader = shader
	_river_material.render_priority = 1
	_river_material.set_shader_parameter("shore_color", _config.river_shore_color)
	_river_material.set_shader_parameter("shallow_color", _config.river_shallow_color)
	_river_material.set_shader_parameter("mid_color", _config.river_mid_color)
	_river_material.set_shader_parameter("deep_color", _config.river_deep_color)
	_river_material.set_shader_parameter("flow_speed", _config.flow_speed)
	_river_material.set_shader_parameter("wave_amplitude", _config.wave_amplitude)
	_river_material.set_shader_parameter("wave_frequency", _config.wave_frequency)
	_river_material.set_shader_parameter("wave_speed", _config.wave_speed)
	_river_material.set_shader_parameter("roughness", _config.roughness)
	_river_material.set_shader_parameter("metallic", _config.metallic)
	_river_material.set_shader_parameter("foam_color", _config.foam_color)
	_river_material.set_shader_parameter("foam_width", _config.foam_width)
	_river_material.set_shader_parameter("foam_noise_scale", _config.foam_noise_scale)
	_river_material.set_shader_parameter("time", 0.0)


# ── Chunk lifecycle ──────────────────────────────────────────────────────────

func _on_terrain_chunk_ready(coord: Vector2i, heightmap: PackedFloat32Array) -> void:
	_chunk_heightmaps[coord] = heightmap

	_clear_chunk(coord)
	if not SharedWorld.river_cells.has(coord):
		return
	var river_cells: Array = SharedWorld.river_cells[coord]
	if river_cells.is_empty():
		return
	var render_paths: Array = SharedWorld.river_paths.get(coord, [])
	var segment_count := _build_chunk_water(coord, river_cells, render_paths, heightmap)
	_rebuild_adjacent_chunks(coord)

	SystemBus.river_chunk_ready.emit(coord, segment_count)


func _on_chunk_unload_requested(coord: Vector2i) -> void:
	_clear_chunk(coord)
	SharedWorld.river_cells.erase(coord)
	SharedWorld.river_paths.erase(coord)
	_chunk_heightmaps.erase(coord)


# ── Build continuous river ribbon mesh ───────────────────────────────────────

func _build_chunk_water(chunk_coord: Vector2i, river_cells: Array, render_paths: Array,
		heightmap: PackedFloat32Array) -> int:
	var res := int(sqrt(heightmap.size()))
	if res <= 0:
		return 0

	var cs: float = GameConfig.chunk_size
	var step := cs / float(res - 1)
	var origin_x := float(chunk_coord.x) * cs
	var origin_z := float(chunk_coord.y) * cs
	var sea: float = SharedWorld.sea_level
	var sea_surface_y := sea + 0.05
	var water_lift := clampf(_config.water_surface_offset * 0.30, 0.06, 0.14)

	var render_cell_map := _build_render_cell_map(river_cells, render_paths, heightmap, res,
		origin_x, origin_z, step, sea_surface_y, water_lift)
	if render_cell_map.is_empty():
		_chunk_sampled_paths.erase(chunk_coord)
		return 0

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var segment_count := 0
	var sampled_paths_for_chunk: Array = []
	if not render_paths.is_empty():
		for render_path in render_paths:
			var dense_render_path := _resample_render_path(render_path, step * 0.55)
			var sampled_path := _sample_render_path(
				dense_render_path,
				heightmap,
				res,
				origin_x,
				origin_z,
				step,
				sea_surface_y,
				water_lift
			)
			if sampled_path.size() < 2:
				continue
			_emit_render_path(st, sampled_path, heightmap, res, origin_x, origin_z, step)
			sampled_paths_for_chunk.append_array(sampled_path)
			segment_count += sampled_path.size() - 1
		for render_cell in render_cell_map.values():
			if not bool(render_cell.get("is_near_sea", false)):
				continue
			if float(render_cell.get("outlet_t", 0.0)) < 0.72:
				continue
			if float(render_cell.get("bank_y", INF)) > sea_surface_y + step * 0.22:
				continue
			_emit_render_cell_top(st, render_cell, step)
			_emit_render_cell_walls(st, render_cell, render_cell_map, heightmap, res,
				origin_x, origin_z, step, sea_surface_y)
	else:
		sampled_paths_for_chunk = render_cell_map.values()
		for render_cell in sampled_paths_for_chunk:
			_emit_render_cell_top(st, render_cell, step)
			segment_count += 1
			_emit_render_cell_walls(st, render_cell, render_cell_map, heightmap, res,
				origin_x, origin_z, step, sea_surface_y)

	var mesh := st.commit()
	if not mesh:
		return 0

	var mat := _river_material.duplicate() as ShaderMaterial
	mat.set_shader_parameter("terrain_depth_tex", _build_river_depth_texture(render_cell_map, heightmap, res))
	mat.set_shader_parameter("chunk_origin_xz", Vector2(origin_x, origin_z))
	mat.set_shader_parameter("chunk_size", cs)
	mat.set_shader_parameter("time", Time.get_ticks_msec() / 1000.0)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	_chunk_meshes[chunk_coord] = mi
	_chunk_materials[chunk_coord] = mat
	_chunk_sampled_paths[chunk_coord] = sampled_paths_for_chunk
	return segment_count


func _build_river_depth_texture(render_cell_map: Dictionary,
		heightmap: PackedFloat32Array, res: int) -> ImageTexture:
	var max_depth := 0.001
	for render_cell in render_cell_map.values():
		max_depth = maxf(max_depth, float(render_cell.get("water_y", 0.0)) - float(render_cell.get("bed_y", 0.0)))
	var image := Image.create(res, res, false, Image.FORMAT_RF)
	for z in res:
		for x in res:
			var terrain_h := heightmap[z * res + x]
			var local_depth := 0.0
			var keys := [
				Vector2i(x, z),
				Vector2i(x - 1, z),
				Vector2i(x, z - 1),
				Vector2i(x - 1, z - 1),
			]
			for key in keys:
				if not render_cell_map.has(key):
					continue
				var render_cell: Dictionary = render_cell_map[key]
				local_depth = maxf(local_depth, float(render_cell.get("water_y", terrain_h)) - terrain_h)
			image.set_pixel(x, z, Color(clampf(local_depth / max_depth, 0.0, 1.0), 0.0, 0.0, 1.0))
	return ImageTexture.create_from_image(image)


func _build_render_cell_map(river_cells: Array, render_paths: Array,
		heightmap: PackedFloat32Array, res: int,
		origin_x: float, origin_z: float, step: float,
		sea_surface_y: float, water_lift: float) -> Dictionary:
	var river_cell_lookup := _build_river_cell_lookup(river_cells)
	var render_stamp_map := _build_render_stamp_map(river_cell_lookup, render_paths,
		origin_x, origin_z, step, res)
	var render_cell_map: Dictionary = {}
	for key_variant in render_stamp_map.keys():
		var cell_key: Vector2i = key_variant
		if not river_cell_lookup.has(cell_key):
			continue
		var river_cell: Dictionary = river_cell_lookup[cell_key]
		var stamp: Dictionary = render_stamp_map[cell_key]
		var gx := cell_key.x
		var gz := cell_key.y
		var idx := gz * res + gx
		var surface_y := float(river_cell.get("surface_y", heightmap[idx]))
		var water_level := float(river_cell.get("water_level", surface_y))
		var channel_depth := maxf(float(river_cell.get("channel_depth", 0.8)), water_lift)
		var channel_fill_ratio := clampf(float(river_cell.get("channel_fill_ratio", 0.72)), 0.25, 0.95)
		var bed_y := _cell_min_height(heightmap, res, gx, gz)
		var bank_y := _cell_max_height(heightmap, res, gx, gz)
		var is_near_sea := bank_y <= sea_surface_y + step * 0.22 or water_level <= sea_surface_y + step * 0.18
		var target_fill_depth := maxf(channel_depth * channel_fill_ratio * 0.94, water_lift * 0.82)
		var min_water_y := bed_y + water_lift * 0.68
		var desired_water_y := maxf(bed_y + target_fill_depth, water_level - water_lift * 0.12)
		var max_water_y := minf(surface_y - 0.03, bank_y - 0.02)
		var water_y := clampf(desired_water_y, min_water_y, max_water_y)
		water_y = maxf(water_y, bed_y + water_lift * 0.68)
		water_y = minf(water_y, surface_y - 0.06)
		if is_near_sea:
			water_y = maxf(water_y, sea_surface_y)
		var depth_t := clampf((water_y - bed_y) / maxf(channel_depth, 0.001), 0.0, 1.0)
		var outlet_t := 0.0
		if is_near_sea:
			outlet_t = clampf(1.0 - ((water_y - sea_surface_y) / maxf(step * 0.75, 0.001)), 0.0, 1.0)
		var x0 := origin_x + float(gx) * step
		var z0 := origin_z + float(gz) * step
		render_cell_map[Vector2i(gx, gz)] = {
			"gx": gx,
			"gz": gz,
			"x0": x0,
			"x1": x0 + step,
			"z0": z0,
			"z1": z0 + step,
			"surface_y": surface_y,
			"water_y": water_y,
			"bed_y": bed_y,
			"bank_y": bank_y,
			"depth_t": depth_t,
			"outlet_t": outlet_t,
			"is_near_sea": is_near_sea,
			"flow_dir_x": float(stamp.get("flow_dir_x", river_cell.get("flow_dir_x", 0.0))),
			"flow_dir_z": float(stamp.get("flow_dir_z", river_cell.get("flow_dir_z", 1.0))),
			"render_half_width": float(stamp.get("half_width", river_cell.get("channel_half_width", step))),
			"support": float(stamp.get("support", 1.0)),
		}
	_apply_shared_corner_heights(render_cell_map, origin_x, origin_z, step)
	return render_cell_map


func _build_river_cell_lookup(river_cells: Array) -> Dictionary:
	var lookup: Dictionary = {}
	for river_cell in river_cells:
		var gx := int(river_cell.get("gx", -1))
		var gz := int(river_cell.get("gz", -1))
		if gx < 0 or gz < 0:
			continue
		lookup[Vector2i(gx, gz)] = river_cell
	return lookup


func _build_render_stamp_map(river_cell_lookup: Dictionary, render_paths: Array,
		origin_x: float, origin_z: float, step: float, res: int) -> Dictionary:
	var stamp_map: Dictionary = {}
	for render_path in render_paths:
		var dense_render_path := _resample_render_path(render_path, step * 0.55)
		for point in dense_render_path:
			var wx := float(point.get("world_x", 0.0))
			var wz := float(point.get("world_z", 0.0))
			var center_gx := clampi(roundi((wx - origin_x) / step), 0, res - 2)
			var center_gz := clampi(roundi((wz - origin_z) / step), 0, res - 2)
			var base_half_width := maxf(float(point.get("half_width", step * 0.5)), step * 0.45)
			var radius_cells := maxi(ceili((base_half_width + step * 0.35) / step), 1)
			var flow_dir_x := float(point.get("flow_dir_x", 0.0))
			var flow_dir_z := float(point.get("flow_dir_z", 1.0))
			for dz in range(-radius_cells, radius_cells + 1):
				for dx in range(-radius_cells, radius_cells + 1):
					var gx := center_gx + dx
					var gz := center_gz + dz
					if gx < 0 or gx >= res - 1 or gz < 0 or gz >= res - 1:
						continue
					var cell_key := Vector2i(gx, gz)
					if not river_cell_lookup.has(cell_key):
						continue
					var river_cell: Dictionary = river_cell_lookup[cell_key]
					var cell_half_width := maxf(float(river_cell.get("channel_half_width", base_half_width)), base_half_width)
					var allowed_width := maxf(base_half_width * 0.95, cell_half_width * 0.82)
					var cell_center_x := origin_x + float(gx) * step
					var cell_center_z := origin_z + float(gz) * step
					var dist := Vector2(cell_center_x - wx, cell_center_z - wz).length()
					if dist > allowed_width + step * 0.28:
						continue
					var support := 1.0 - clampf(dist / maxf(allowed_width + step * 0.28, 0.001), 0.0, 1.0)
					var stamp: Dictionary = stamp_map.get(cell_key, {
						"support": 0.0,
						"half_width": 0.0,
						"flow_dir_x": flow_dir_x,
						"flow_dir_z": flow_dir_z,
					})
					stamp["support"] = maxf(float(stamp.get("support", 0.0)), support)
					stamp["half_width"] = maxf(float(stamp.get("half_width", 0.0)), allowed_width)
					if support >= float(stamp.get("support", 0.0)):
						stamp["flow_dir_x"] = flow_dir_x
						stamp["flow_dir_z"] = flow_dir_z
					stamp_map[cell_key] = stamp
	return stamp_map


func _cell_min_height(heightmap: PackedFloat32Array, res: int, gx: int, gz: int) -> float:
	var h00 := _sample_hm(heightmap, res, gx, gz)
	var h10 := _sample_hm(heightmap, res, gx + 1, gz)
	var h01 := _sample_hm(heightmap, res, gx, gz + 1)
	var h11 := _sample_hm(heightmap, res, gx + 1, gz + 1)
	return minf(minf(h00, h10), minf(h01, h11))


func _cell_avg_height(heightmap: PackedFloat32Array, res: int, gx: int, gz: int) -> float:
	var h00 := _sample_hm(heightmap, res, gx, gz)
	var h10 := _sample_hm(heightmap, res, gx + 1, gz)
	var h01 := _sample_hm(heightmap, res, gx, gz + 1)
	var h11 := _sample_hm(heightmap, res, gx + 1, gz + 1)
	return (h00 + h10 + h01 + h11) * 0.25


func _cell_max_height(heightmap: PackedFloat32Array, res: int, gx: int, gz: int) -> float:
	var h00 := _sample_hm(heightmap, res, gx, gz)
	var h10 := _sample_hm(heightmap, res, gx + 1, gz)
	var h01 := _sample_hm(heightmap, res, gx, gz + 1)
	var h11 := _sample_hm(heightmap, res, gx + 1, gz + 1)
	return maxf(maxf(h00, h10), maxf(h01, h11))


func _apply_shared_corner_heights(render_cell_map: Dictionary,
		origin_x: float, origin_z: float, step: float) -> void:
	var corner_height_map: Dictionary = {}
	for key_variant in render_cell_map.keys():
		var cell_key: Vector2i = key_variant
		var corner_keys := [
			Vector2i(cell_key.x, cell_key.y),
			Vector2i(cell_key.x + 1, cell_key.y),
			Vector2i(cell_key.x + 1, cell_key.y + 1),
			Vector2i(cell_key.x, cell_key.y + 1),
		]
		for corner_key in corner_keys:
			if corner_height_map.has(corner_key):
				continue
			corner_height_map[corner_key] = _shared_corner_height(render_cell_map, corner_key)
	for key_variant in render_cell_map.keys():
		var cell_key: Vector2i = key_variant
		var cell: Dictionary = render_cell_map[cell_key]
		var nw_key := Vector2i(cell_key.x, cell_key.y)
		var ne_key := Vector2i(cell_key.x + 1, cell_key.y)
		var se_key := Vector2i(cell_key.x + 1, cell_key.y + 1)
		var sw_key := Vector2i(cell_key.x, cell_key.y + 1)
		var x0 := origin_x + float(cell_key.x) * step
		var x1 := x0 + step
		var z0 := origin_z + float(cell_key.y) * step
		var z1 := z0 + step
		cell["nw"] = Vector3(x0, float(corner_height_map[nw_key]), z0)
		cell["ne"] = Vector3(x1, float(corner_height_map[ne_key]), z0)
		cell["se"] = Vector3(x1, float(corner_height_map[se_key]), z1)
		cell["sw"] = Vector3(x0, float(corner_height_map[sw_key]), z1)
		render_cell_map[cell_key] = cell


func _shared_corner_height(render_cell_map: Dictionary, corner_key: Vector2i) -> float:
	var touching_cells := [
		Vector2i(corner_key.x, corner_key.y),
		Vector2i(corner_key.x - 1, corner_key.y),
		Vector2i(corner_key.x, corner_key.y - 1),
		Vector2i(corner_key.x - 1, corner_key.y - 1),
	]
	var sum_height := 0.0
	var count := 0
	var max_height := -INF
	for cell_key in touching_cells:
		if not render_cell_map.has(cell_key):
			continue
		var render_cell: Dictionary = render_cell_map[cell_key]
		var water_y := float(render_cell.get("water_y", 0.0))
		sum_height += water_y
		max_height = maxf(max_height, water_y)
		count += 1
	if count == 0:
		return 0.0
	var avg_height := sum_height / float(count)
	return lerpf(avg_height, max_height, 0.45)


func _emit_render_cell_top(st: SurfaceTool, render_cell: Dictionary, _step: float) -> void:
	var depth_t := float(render_cell["depth_t"])
	var flow := Vector2(float(render_cell.get("flow_dir_x", 0.0)), float(render_cell.get("flow_dir_z", 1.0)))
	if flow.length_squared() < 0.0001:
		flow = Vector2(0.0, 1.0)
	else:
		flow = flow.normalized()
	var along_scale := 0.18
	var nw: Vector3 = render_cell["nw"]
	var ne: Vector3 = render_cell["ne"]
	var se: Vector3 = render_cell["se"]
	var sw: Vector3 = render_cell["sw"]
	var normal := _quad_normal(nw, ne, se, sw)
	var v_nw := Vector2(nw.x, nw.z).dot(flow) * along_scale
	var v_ne := Vector2(ne.x, ne.z).dot(flow) * along_scale
	var v_se := Vector2(se.x, se.z).dot(flow) * along_scale
	var v_sw := Vector2(sw.x, sw.z).dot(flow) * along_scale
	st.set_normal(normal)
	st.set_color(Color(depth_t, depth_t, depth_t, 1.0))
	st.set_uv(Vector2(0.0, v_nw))
	st.add_vertex(nw)
	st.set_color(Color(depth_t, depth_t, depth_t, 1.0))
	st.set_uv(Vector2(1.0, v_ne))
	st.add_vertex(ne)
	st.set_color(Color(depth_t, depth_t, depth_t, 1.0))
	st.set_uv(Vector2(1.0, v_se))
	st.add_vertex(se)
	st.set_normal(normal)
	st.set_color(Color(depth_t, depth_t, depth_t, 1.0))
	st.set_uv(Vector2(0.0, v_nw))
	st.add_vertex(nw)
	st.set_color(Color(depth_t, depth_t, depth_t, 1.0))
	st.set_uv(Vector2(1.0, v_se))
	st.add_vertex(se)
	st.set_color(Color(depth_t, depth_t, depth_t, 1.0))
	st.set_uv(Vector2(0.0, v_sw))
	st.add_vertex(sw)


func _emit_render_cell_walls(st: SurfaceTool, render_cell: Dictionary, render_cell_map: Dictionary,
		heightmap: PackedFloat32Array, res: int,
		origin_x: float, origin_z: float, step: float, sea: float) -> int:
	var wall_count := 0
	var gx := int(render_cell["gx"])
	var gz := int(render_cell["gz"])
	var water_y := float(render_cell["water_y"])
	var depth_t := float(render_cell["depth_t"])
	var outlet_t := float(render_cell.get("outlet_t", 0.0))
	var x0 := float(render_cell["x0"])
	var x1 := float(render_cell["x1"])
	var z0 := float(render_cell["z0"])
	var z1 := float(render_cell["z1"])
	var nw: Vector3 = render_cell["nw"]
	var ne: Vector3 = render_cell["ne"]
	var se: Vector3 = render_cell["se"]
	var sw: Vector3 = render_cell["sw"]
	var edges := [
		{"neighbor": Vector2i(gx, gz - 1), "a": nw, "b": ne, "axis": Vector2(x0, z0), "axis_to": Vector2(x1, z0)},
		{"neighbor": Vector2i(gx + 1, gz), "a": ne, "b": se, "axis": Vector2(x1, z0), "axis_to": Vector2(x1, z1)},
		{"neighbor": Vector2i(gx, gz + 1), "a": se, "b": sw, "axis": Vector2(x1, z1), "axis_to": Vector2(x0, z1)},
		{"neighbor": Vector2i(gx - 1, gz), "a": sw, "b": nw, "axis": Vector2(x0, z1), "axis_to": Vector2(x0, z0)},
	]
	for edge in edges:
		var neighbor_key: Vector2i = edge["neighbor"]
		if render_cell_map.has(neighbor_key):
			var neighbor: Dictionary = render_cell_map[neighbor_key]
			if float(neighbor.get("water_y", -INF)) >= water_y - 0.01:
				continue
		var top_a: Vector3 = edge["a"]
		var top_b: Vector3 = edge["b"]
		var edge_from: Vector2 = edge["axis"]
		var edge_to: Vector2 = edge["axis_to"]
		var bottom_y_a := _sample_hm_bilinear(heightmap, res, origin_x, origin_z, step, edge_from.x, edge_from.y)
		var bottom_y_b := _sample_hm_bilinear(heightmap, res, origin_x, origin_z, step, edge_to.x, edge_to.y)
		bottom_y_a = maxf(bottom_y_a, sea)
		bottom_y_b = maxf(bottom_y_b, sea)
		if outlet_t > 0.35 and bottom_y_a <= sea + 0.08 and bottom_y_b <= sea + 0.08:
			continue
		if top_a.y <= bottom_y_a + 0.01 and top_b.y <= bottom_y_b + 0.01:
			continue
		_emit_bank_strip(st, top_a, top_b, bottom_y_a, bottom_y_b, depth_t, depth_t, 0.0, 1.0)
		wall_count += 1
	return wall_count


func system_process(_delta: float) -> void:
	if not active:
		return
	var time := Time.get_ticks_msec() / 1000.0
	for coord in _chunk_materials.keys():
		var mat: ShaderMaterial = _chunk_materials[coord]
		if mat:
			mat.set_shader_parameter("time", time)


func _resample_render_path(render_path: Array, max_spacing: float) -> Array:
	if render_path.size() < 2:
		return render_path.duplicate(true)
	var spacing := maxf(max_spacing, 0.25)
	var dense_path: Array = [render_path[0].duplicate(true)]
	for i in range(render_path.size() - 1):
		var a: Dictionary = render_path[i]
		var b: Dictionary = render_path[i + 1]
		var a_pos := Vector2(float(a["world_x"]), float(a["world_z"]))
		var b_pos := Vector2(float(b["world_x"]), float(b["world_z"]))
		var seg_len := a_pos.distance_to(b_pos)
		var steps := maxi(int(ceili(seg_len / spacing)), 1)
		for s in range(1, steps + 1):
			var t := float(s) / float(steps)
			dense_path.append({
				"world_x": lerpf(float(a["world_x"]), float(b["world_x"]), t),
				"world_z": lerpf(float(a["world_z"]), float(b["world_z"]), t),
				"surface_y": lerpf(float(a.get("surface_y", 0.0)), float(b.get("surface_y", 0.0)), t),
				"river_t": lerpf(float(a.get("river_t", 0.0)), float(b.get("river_t", 0.0)), t),
				"half_width": lerpf(float(a.get("half_width", 0.6)), float(b.get("half_width", 0.6)), t),
				"flow_dir_x": lerpf(float(a.get("flow_dir_x", 0.0)), float(b.get("flow_dir_x", 0.0)), t),
				"flow_dir_z": lerpf(float(a.get("flow_dir_z", 1.0)), float(b.get("flow_dir_z", 1.0)), t),
			})
	return dense_path


func _extend_render_path_ends(render_path: Array, extension_dist: float) -> Array:
	if render_path.size() < 2:
		return render_path.duplicate(true)
	var extended_path := render_path.duplicate(true)
	var extension := maxf(extension_dist, 0.25)

	var first: Dictionary = extended_path[0]
	var second: Dictionary = extended_path[1]
	var start_dir := Vector2(float(first.get("flow_dir_x", 0.0)), float(first.get("flow_dir_z", 1.0)))
	if start_dir.length_squared() < 0.0001:
		start_dir = Vector2(float(second["world_x"]) - float(first["world_x"]), float(second["world_z"]) - float(first["world_z"]))
	if start_dir.length_squared() < 0.0001:
		start_dir = Vector2(0.0, 1.0)
	start_dir = start_dir.normalized()
	var start_point := first.duplicate(true)
	start_point["world_x"] = float(first["world_x"]) - start_dir.x * extension
	start_point["world_z"] = float(first["world_z"]) - start_dir.y * extension
	extended_path.insert(0, start_point)

	var last: Dictionary = extended_path[extended_path.size() - 1]
	var prev: Dictionary = extended_path[extended_path.size() - 2]
	var end_dir := Vector2(float(last.get("flow_dir_x", 0.0)), float(last.get("flow_dir_z", 1.0)))
	if end_dir.length_squared() < 0.0001:
		end_dir = Vector2(float(last["world_x"]) - float(prev["world_x"]), float(last["world_z"]) - float(prev["world_z"]))
	if end_dir.length_squared() < 0.0001:
		end_dir = Vector2(0.0, 1.0)
	end_dir = end_dir.normalized()
	var end_point := last.duplicate(true)
	end_point["world_x"] = float(last["world_x"]) + end_dir.x * extension
	end_point["world_z"] = float(last["world_z"]) + end_dir.y * extension
	end_point["surface_y"] = float(last.get("surface_y", 0.0))
	extended_path.append(end_point)
	return extended_path


func _sample_render_path(render_path: Array, heightmap: PackedFloat32Array, res: int,
		origin_x: float, origin_z: float, step: float,
		sea_surface_y: float, water_lift: float) -> Array:
	var sampled_points: Array = []
	var prev_water_y := INF
	var accumulated_v := 0.0
	for i in range(render_path.size()):
		var point: Dictionary = render_path[i]
		if not point.has("world_x") or not point.has("world_z"):
			continue
		var wx := float(point["world_x"])
		var wz := float(point["world_z"])
		if wx < origin_x or wx > origin_x + GameConfig.chunk_size or wz < origin_z or wz > origin_z + GameConfig.chunk_size:
			continue
		var outlet_t := clampf(1.0 - ((float(point.get("surface_y", sea_surface_y)) - sea_surface_y) / maxf(step * 1.5, 0.001)), 0.0, 1.0)
		var base_half_width := maxf(float(point.get("half_width", 0.6)) * 0.62, step * 0.22)
		var half_width := base_half_width * lerpf(1.0, 1.35, outlet_t)
		var bed_y := _sample_hm_bilinear(heightmap, res, origin_x, origin_z, step, wx, wz)
		var original_surface_y := float(point.get("surface_y", bed_y))
		var channel_depth := maxf(original_surface_y - bed_y, 0.0)
		var min_fill := clampf(maxf(channel_depth * 0.35, half_width * 0.18), water_lift, 0.28)
		var max_surface_y := original_surface_y - 0.02
		var target_water_y := bed_y + min_fill
		var water_y := minf(target_water_y, max_surface_y)
		water_y = maxf(water_y, bed_y + water_lift)
		if prev_water_y != INF and water_y > prev_water_y:
			water_y = prev_water_y
		water_y = maxf(water_y, sea_surface_y)
		var depth_t := clampf((water_y - bed_y) / 0.35, 0.0, 1.0)
		var center := Vector3(wx, water_y, wz)
		if not sampled_points.is_empty():
			var prev_center: Vector3 = sampled_points[sampled_points.size() - 1]["center"]
			accumulated_v += Vector2(center.x - prev_center.x, center.z - prev_center.z).length()
		sampled_points.append({
			"center": center,
			"half_width": half_width,
			"depth_t": depth_t,
			"bed_y": bed_y,
			"flow_dir_x": float(point.get("flow_dir_x", 0.0)),
			"flow_dir_z": float(point.get("flow_dir_z", 1.0)),
			"uv_v": accumulated_v,
		})
		prev_water_y = water_y
	if sampled_points.size() < 2:
		return sampled_points
	_smooth_sampled_centers(sampled_points)
	for i in range(sampled_points.size()):
		var tangent := _path_tangent(sampled_points, i)
		var center: Vector3 = sampled_points[i]["center"]
		var bend_widen := _bend_widen_factor(sampled_points, i)
		var widths := _probe_bank_widths(heightmap, res, origin_x, origin_z, step,
			center, tangent, float(sampled_points[i]["half_width"]) * bend_widen, bend_widen)
		var left_width: float = float(widths["left_width"])
		var right_width: float = float(widths["right_width"])
		var perp := Vector2(-tangent.y, tangent.x)
		sampled_points[i]["left_width"] = left_width
		sampled_points[i]["right_width"] = right_width
		sampled_points[i]["left"] = Vector3(center.x - perp.x * left_width, center.y, center.z - perp.y * left_width)
		sampled_points[i]["right"] = Vector3(center.x + perp.x * right_width, center.y, center.z + perp.y * right_width)
	return sampled_points


func _smooth_sampled_centers(sampled_points: Array) -> void:
	if sampled_points.size() < 3:
		return
	var original_centers: Array = []
	for point in sampled_points:
		original_centers.append(point["center"])
	for i in range(1, sampled_points.size() - 1):
		var prev_center: Vector3 = original_centers[i - 1]
		var center: Vector3 = original_centers[i]
		var next_center: Vector3 = original_centers[i + 1]
		var avg_x := (prev_center.x + center.x + next_center.x) / 3.0
		var avg_z := (prev_center.z + center.z + next_center.z) / 3.0
		sampled_points[i]["center"] = Vector3(
			lerpf(center.x, avg_x, 0.35),
			center.y,
			lerpf(center.z, avg_z, 0.35)
		)
	var accumulated_v := 0.0
	for i in range(sampled_points.size()):
		if i > 0:
			var prev_center: Vector3 = sampled_points[i - 1]["center"]
			var center: Vector3 = sampled_points[i]["center"]
			accumulated_v += Vector2(center.x - prev_center.x, center.z - prev_center.z).length()
		sampled_points[i]["uv_v"] = accumulated_v


func _bend_widen_factor(sampled_points: Array, index: int) -> float:
	if index <= 0 or index >= sampled_points.size() - 1:
		return 1.0
	var prev_center: Vector3 = sampled_points[index - 1]["center"]
	var center: Vector3 = sampled_points[index]["center"]
	var next_center: Vector3 = sampled_points[index + 1]["center"]
	var in_dir := Vector2(center.x - prev_center.x, center.z - prev_center.z)
	var out_dir := Vector2(next_center.x - center.x, next_center.z - center.z)
	if in_dir.length_squared() < 0.0001 or out_dir.length_squared() < 0.0001:
		return 1.0
	in_dir = in_dir.normalized()
	out_dir = out_dir.normalized()
	var bend_strength := clampf((1.0 - in_dir.dot(out_dir)) * 0.5, 0.0, 1.0)
	return lerpf(1.0, 1.65, bend_strength)


func _probe_bank_widths(heightmap: PackedFloat32Array, res: int,
		origin_x: float, origin_z: float, step: float,
		center: Vector3, tangent: Vector2, fallback_half_width: float,
		bend_widen: float) -> Dictionary:
	var perp := Vector2(-tangent.y, tangent.x)
	if perp.length_squared() < 0.0001:
		perp = Vector2(1.0, 0.0)
	else:
		perp = perp.normalized()
	var sample_step := maxf(step * 0.35, 0.2)
	var max_width := maxf(fallback_half_width * 1.75, sample_step)
	var threshold_y := center.y - lerpf(0.02, 0.10, clampf(bend_widen - 1.0, 0.0, 0.65) / 0.65)
	var left_width := _probe_bank_width(heightmap, res, origin_x, origin_z, step,
		Vector2(center.x, center.z), -perp, sample_step, max_width, threshold_y)
	var right_width := _probe_bank_width(heightmap, res, origin_x, origin_z, step,
		Vector2(center.x, center.z), perp, sample_step, max_width, threshold_y)
	return {
		"left_width": left_width,
		"right_width": right_width,
	}


func _probe_bank_width(heightmap: PackedFloat32Array, res: int,
		origin_x: float, origin_z: float, step: float,
		center_xz: Vector2, direction: Vector2,
		sample_step: float, max_width: float, threshold_y: float) -> float:
	var last_open_width := minf(max_width, sample_step * 0.75)
	var dist := sample_step
	while dist <= max_width:
		var pos := center_xz + direction * dist
		var terrain_y := _sample_hm_bilinear(heightmap, res, origin_x, origin_z, step, pos.x, pos.y)
		if terrain_y >= threshold_y:
			break
		last_open_width = dist
		dist += sample_step
	return maxf(last_open_width, sample_step * 0.5)


func _emit_render_path(st: SurfaceTool, sampled_points: Array,
		heightmap: PackedFloat32Array, res: int,
		origin_x: float, origin_z: float, step: float) -> void:
	for i in range(sampled_points.size() - 1):
		var a: Dictionary = sampled_points[i]
		var b: Dictionary = sampled_points[i + 1]
		var left_a: Vector3 = a["left"]
		var right_a: Vector3 = a["right"]
		var left_b: Vector3 = b["left"]
		var right_b: Vector3 = b["right"]
		var normal := _quad_normal(left_a, right_a, right_b, left_b)
		_emit_strip_quad(st, left_a, right_a, right_b, left_b,
			float(a["uv_v"]), float(b["uv_v"]),
			float(a.get("depth_t", 0.5)), float(b.get("depth_t", 0.5)), normal)

		var left_bed_a := _sample_hm_bilinear(heightmap, res, origin_x, origin_z, step, left_a.x, left_a.z)
		var left_bed_b := _sample_hm_bilinear(heightmap, res, origin_x, origin_z, step, left_b.x, left_b.z)
		_emit_bank_strip(st, left_a, left_b, left_bed_a, left_bed_b,
			float(a.get("depth_t", 0.5)), float(b.get("depth_t", 0.5)),
			float(a["uv_v"]), float(b["uv_v"]))

		var right_bed_a := _sample_hm_bilinear(heightmap, res, origin_x, origin_z, step, right_a.x, right_a.z)
		var right_bed_b := _sample_hm_bilinear(heightmap, res, origin_x, origin_z, step, right_b.x, right_b.z)
		_emit_bank_strip(st, right_b, right_a, right_bed_b, right_bed_a,
			float(b.get("depth_t", 0.5)), float(a.get("depth_t", 0.5)),
			float(b["uv_v"]), float(a["uv_v"]))


func _emit_strip_quad(st: SurfaceTool,
		left_a: Vector3, right_a: Vector3, right_b: Vector3, left_b: Vector3,
		v0: float, v1: float, depth_a: float, depth_b: float, normal: Vector3) -> void:
	st.set_normal(normal)
	st.set_color(Color(depth_a, depth_a, depth_a, 1.0))
	st.set_uv(Vector2(0.0, v0))
	st.add_vertex(left_a)
	st.set_color(Color(depth_a, depth_a, depth_a, 1.0))
	st.set_uv(Vector2(1.0, v0))
	st.add_vertex(right_a)
	st.set_color(Color(depth_b, depth_b, depth_b, 1.0))
	st.set_uv(Vector2(1.0, v1))
	st.add_vertex(right_b)
	st.set_normal(normal)
	st.set_color(Color(depth_a, depth_a, depth_a, 1.0))
	st.set_uv(Vector2(0.0, v0))
	st.add_vertex(left_a)
	st.set_color(Color(depth_b, depth_b, depth_b, 1.0))
	st.set_uv(Vector2(1.0, v1))
	st.add_vertex(right_b)
	st.set_color(Color(depth_b, depth_b, depth_b, 1.0))
	st.set_uv(Vector2(0.0, v1))
	st.add_vertex(left_b)


func _emit_bank_strip(st: SurfaceTool,
		top_a: Vector3, top_b: Vector3,
		bed_y_a: float, bed_y_b: float,
		depth_a: float, depth_b: float,
		v0: float, v1: float) -> void:
	if top_a.y <= bed_y_a + 0.01 and top_b.y <= bed_y_b + 0.01:
		return
	var bottom_a := Vector3(top_a.x, minf(top_a.y - 0.01, bed_y_a), top_a.z)
	var bottom_b := Vector3(top_b.x, minf(top_b.y - 0.01, bed_y_b), top_b.z)
	var normal := _quad_normal(top_a, top_b, bottom_b, bottom_a)
	st.set_normal(normal)
	st.set_color(Color(depth_a, depth_a, depth_a, 1.0))
	st.set_uv(Vector2(0.0, v0))
	st.add_vertex(top_a)
	st.set_color(Color(depth_b, depth_b, depth_b, 1.0))
	st.set_uv(Vector2(0.0, v1))
	st.add_vertex(top_b)
	st.set_color(Color(depth_b, depth_b, depth_b, 1.0))
	st.set_uv(Vector2(1.0, v1))
	st.add_vertex(bottom_b)
	st.set_normal(normal)
	st.set_color(Color(depth_a, depth_a, depth_a, 1.0))
	st.set_uv(Vector2(0.0, v0))
	st.add_vertex(top_a)
	st.set_color(Color(depth_b, depth_b, depth_b, 1.0))
	st.set_uv(Vector2(1.0, v1))
	st.add_vertex(bottom_b)
	st.set_color(Color(depth_a, depth_a, depth_a, 1.0))
	st.set_uv(Vector2(1.0, v0))
	st.add_vertex(bottom_a)


func _path_tangent(sampled_points: Array, index: int) -> Vector2:
	var center: Vector3 = sampled_points[index]["center"]
	var tangent := Vector2.ZERO
	if index > 0:
		var prev_center: Vector3 = sampled_points[index - 1]["center"]
		tangent += Vector2(center.x - prev_center.x, center.z - prev_center.z)
	if index < sampled_points.size() - 1:
		var next_center: Vector3 = sampled_points[index + 1]["center"]
		tangent += Vector2(next_center.x - center.x, next_center.z - center.z)
	if tangent.length_squared() < 0.0001:
		tangent = Vector2(float(sampled_points[index]["flow_dir_x"]), float(sampled_points[index]["flow_dir_z"]))
	if tangent.length_squared() < 0.0001:
		return Vector2(0.0, 1.0)
	return tangent.normalized()


func _sample_hm(heightmap: PackedFloat32Array, res: int, gx: int, gz: int) -> float:
	gx = clampi(gx, 0, res - 1)
	gz = clampi(gz, 0, res - 1)
	return heightmap[gz * res + gx]


func _sample_hm_bilinear(heightmap: PackedFloat32Array, res: int,
		origin_x: float, origin_z: float, step: float,
		wx: float, wz: float) -> float:
	var lx := clampf((wx - origin_x) / step, 0.0, float(res - 1))
	var lz := clampf((wz - origin_z) / step, 0.0, float(res - 1))
	var gx0 := mini(int(lx), res - 2)
	var gz0 := mini(int(lz), res - 2)
	var fx := lx - float(gx0)
	var fz := lz - float(gz0)
	var h00 := heightmap[gz0 * res + gx0]
	var h10 := heightmap[gz0 * res + gx0 + 1]
	var h01 := heightmap[(gz0 + 1) * res + gx0]
	var h11 := heightmap[(gz0 + 1) * res + gx0 + 1]
	return lerpf(lerpf(h00, h10, fx), lerpf(h01, h11, fx), fz)


func _quad_normal(a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> Vector3:
	var n := (b - a).cross(d - a) + (c - b).cross(a - b)
	if n.length_squared() < 0.0001:
		return Vector3.UP
	n = n.normalized()
	if n.y < 0.0:
		n = -n
	return n


func _rebuild_adjacent_chunks(coord: Vector2i) -> void:
	var offsets := [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.UP, Vector2i.DOWN]
	for offset in offsets:
		var neighbor_coord: Vector2i = coord + offset
		if not SharedWorld.river_cells.has(neighbor_coord):
			continue
		if not _chunk_heightmaps.has(neighbor_coord):
			continue
		var neighbor_cells: Array = SharedWorld.river_cells[neighbor_coord]
		if neighbor_cells.is_empty():
			continue
		var neighbor_paths: Array = SharedWorld.river_paths.get(neighbor_coord, [])
		_clear_chunk(neighbor_coord)
		_build_chunk_water(neighbor_coord, neighbor_cells, neighbor_paths, _chunk_heightmaps[neighbor_coord])


func get_water_surface_height_at(world_pos: Vector3) -> float:
	var chunk_coord := SharedWorld.world_to_chunk(world_pos)
	var best_surface := -INF
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var coord := chunk_coord + Vector2i(dx, dz)
			if not _chunk_sampled_paths.has(coord):
				continue
			var sampled_entries: Array = _chunk_sampled_paths[coord]
			for entry in sampled_entries:
				if entry.has("x0"):
					var x0 := float(entry.get("x0", INF))
					var x1 := float(entry.get("x1", -INF))
					var z0 := float(entry.get("z0", INF))
					var z1 := float(entry.get("z1", -INF))
					if world_pos.x < x0 or world_pos.x > x1 or world_pos.z < z0 or world_pos.z > z1:
						continue
					best_surface = maxf(best_surface, float(entry.get("water_y", -INF)))
					continue
				if not entry.has("center"):
					continue
				var center: Vector3 = entry["center"]
				var left_width := float(entry.get("left_width", entry.get("half_width", 0.0)))
				var right_width := float(entry.get("right_width", entry.get("half_width", 0.0)))
				var half_length := maxf(maxf(left_width, right_width), 0.35)
				if absf(world_pos.x - center.x) > half_length or absf(world_pos.z - center.z) > half_length:
					continue
				best_surface = maxf(best_surface, center.y)
	return best_surface


# ── Cleanup ──────────────────────────────────────────────────────────────────

func _clear_chunk(coord: Vector2i) -> void:
	if _chunk_meshes.has(coord):
		var mi: MeshInstance3D = _chunk_meshes[coord]
		if is_instance_valid(mi):
			mi.queue_free()
		_chunk_meshes.erase(coord)
	_chunk_materials.erase(coord)
	_chunk_sampled_paths.erase(coord)


func _shutdown() -> void:
	for coord in _chunk_meshes.keys():
		_clear_chunk(coord)


# ── Shader ───────────────────────────────────────────────────────────────────

func _get_river_shader_code() -> String:
	return """
shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_disabled, specular_schlick_ggx;

uniform vec4 shore_color : source_color = vec4(0.34, 0.68, 0.64, 0.50);
uniform vec4 shallow_color : source_color = vec4(0.30, 0.55, 0.65, 0.70);
uniform vec4 mid_color : source_color = vec4(0.10, 0.32, 0.48, 0.80);
uniform vec4 deep_color : source_color = vec4(0.15, 0.35, 0.50, 0.85);
uniform vec4 foam_color : source_color = vec4(0.92, 0.95, 1.0, 0.9);
uniform float foam_width = 0.7;
uniform float foam_noise_scale = 7.0;
uniform float flow_speed : hint_range(0.0, 5.0) = 1.2;
uniform float wave_amplitude = 0.05;
uniform float wave_frequency = 1.4;
uniform float wave_speed = 0.75;
uniform float roughness : hint_range(0.0, 1.0) = 0.05;
uniform float metallic : hint_range(0.0, 1.0) = 0.2;
uniform float time = 0.0;
uniform vec2 chunk_origin_xz = vec2(0.0);
uniform float chunk_size = 32.0;
uniform sampler2D DEPTH_TEXTURE : hint_depth_texture, filter_linear_mipmap;
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D terrain_depth_tex : source_color, filter_linear_mipmap, repeat_disable;

varying vec3 v_world_pos;
varying float v_terrain_depth;

vec3 wave_normal(vec2 pos, float along, float t) {
	float dx = 0.0;
	float dz = 0.0;
	float p1 = along * wave_frequency * 2.0 - t * flow_speed * 2.4;
	dx += cos(p1 + pos.x * 0.04) * 0.18;
	dz += sin(p1 + pos.y * 0.03) * 0.35;
	float p2 = along * wave_frequency * 3.6 - t * wave_speed * 3.2;
	dx += cos(p2 - pos.y * 0.05) * 0.10;
	dz += sin(p2 + pos.x * 0.02) * 0.22;
	float p3 = (pos.x + pos.y) * 0.08 - t * wave_speed * 1.2;
	dx += cos(p3) * 0.05;
	dz += sin(p3) * 0.05;
	return normalize(vec3(-dx, 1.0, -dz));
}

vec4 depth_zone_color(float d) {
	if (d < 0.28) {
		return mix(shore_color, shallow_color, smoothstep(0.0, 0.28, d));
	} else if (d < 0.68) {
		return mix(shallow_color, mid_color, smoothstep(0.28, 0.68, d));
	}
	return mix(mid_color, deep_color, smoothstep(0.68, 1.0, d));
}

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 local_uv = clamp((v_world_pos.xz - chunk_origin_xz) / max(chunk_size, 0.001), vec2(0.0), vec2(1.0));
	v_terrain_depth = texture(terrain_depth_tex, local_uv).r;
	float flow_wave = sin(UV.y * wave_frequency * 5.0 - time * flow_speed * 3.0 + v_world_pos.x * 0.03 + v_world_pos.z * 0.02);
	float lateral_wave = sin(UV.x * 6.2831 + UV.y * wave_frequency * 2.2 - time * wave_speed * 2.0);
	float depth_factor = mix(0.35, 1.0, v_terrain_depth);
	VERTEX.y += (flow_wave * 0.7 + lateral_wave * 0.3) * wave_amplitude * depth_factor;
}

void fragment() {
	float depth_t = clamp(COLOR.r, 0.0, 1.0);
	vec3 wn = wave_normal(v_world_pos.xz, UV.y, time * wave_speed);
	float depth_raw = textureLod(DEPTH_TEXTURE, SCREEN_UV, 0.0).r;
	vec4 ndc = vec4(SCREEN_UV * 2.0 - 1.0, depth_raw, 1.0);
	vec4 view_depth = INV_PROJECTION_MATRIX * ndc;
	view_depth.xyz /= view_depth.w;
	float scene_depth = -view_depth.z;
	float water_depth = -VERTEX.z;
	float depth_diff = scene_depth - water_depth;
	float depth_blend = max(clamp(depth_diff / 1.8, 0.0, 1.0), v_terrain_depth);
	vec4 water_col = depth_zone_color(depth_blend);
	float edge_factor = 1.0 - smoothstep(0.08, 0.30, min(UV.x, 1.0 - UV.x));
	float foam_factor = 1.0 - clamp(depth_diff / max(foam_width, 0.001), 0.0, 1.0);
	foam_factor = max(foam_factor, edge_factor * (1.0 - smoothstep(0.12, 0.55, depth_t)));
	float fn1 = sin(v_world_pos.x * foam_noise_scale + time * 2.0) * 0.5 + 0.5;
	float fn2 = sin(v_world_pos.z * foam_noise_scale * 0.75 + time * 1.5) * 0.5 + 0.5;
	float fn3 = sin((v_world_pos.x + v_world_pos.z) * foam_noise_scale * 0.5 - time * 1.8) * 0.5 + 0.5;
	float foam_noise = fn1 * fn2 * 0.7 + fn3 * 0.3;
	foam_factor *= step(0.24, foam_noise + foam_factor * 0.35);
	float crest = pow(1.0 - clamp(wn.y, 0.0, 1.0), 3.0) * 1.5;
	foam_factor = max(foam_factor, crest * depth_blend * 0.45);
	vec2 refraction_uv = SCREEN_UV + wn.xz * 0.015 * (1.0 - depth_blend);
	vec3 refracted = textureLod(SCREEN_TEXTURE, refraction_uv, 0.0).rgb;
	vec3 final_color = mix(water_col.rgb, foam_color.rgb, foam_factor * 0.68);
	final_color = mix(refracted, final_color, water_col.a);
	float final_alpha = mix(water_col.a, foam_color.a, foam_factor * 0.45);

	ALBEDO = final_color;
	ALPHA = clamp(final_alpha + depth_blend * 0.22, 0.0, 1.0);
	NORMAL = mix(vec3(0.0, 1.0, 0.0), wn, mix(0.4, 1.0, depth_blend));
	ROUGHNESS = mix(0.02, roughness, depth_blend);
	METALLIC = metallic;
	SPECULAR = 0.5;
}
"""
