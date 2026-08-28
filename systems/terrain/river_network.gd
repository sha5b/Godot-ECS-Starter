class_name RiverNetwork
extends RefCounted

## The world's drainage network, derived once from the macro height field.
##
## Rivers used to be placed by noise: every chunk searched its neighbourhood
## for cells where a source noise crossed a threshold, then traced a path
## downhill from each one. Four hand-tuned mechanisms sat on top of that to
## fake what a real network does for free — a width ramp from "how far the
## source has dropped", a flood fill to widen the channel, a rejection test
## for paths that failed to reach the sea, and nothing at all for tributaries,
## which simply overlapped.
##
## This computes the one quantity all four were approximating: how much land
## drains through each cell. Everything else falls out of it.
##
##   width      = hydraulic geometry over drainage area
##   depth      = the same, at a shallower exponent
##   tributaries= two channels merging add their areas, so the trunk widens
##   the sea    = depressions are filled before routing, so every channel
##                either reaches the ocean or leaves the domain
##
## Pure computation. No scene tree, no autoloads — it takes a height sampler
## and returns data, which is what makes it measurable from a headless probe.
##
## Runs on the MACRO field, not on chunk heightmaps. A drainage network is a
## global fact about the terrain; a per-chunk one disagrees with its
## neighbours at every seam.

## Neighbour offsets, D8. Index into these is what `flow_dir` stores.
const DX: Array[int] = [1, 1, 0, -1, -1, -1, 0, 1]
const DZ: Array[int] = [0, 1, 1, 1, 0, -1, -1, -1]

## Sentinel in `flow_dir` for a cell that drains nowhere: the ocean, or the
## edge of the domain.
const SINK := 255

# ── Lattice ──────────────────────────────────────────────────────────────────

## World position of cell (0, 0).
var origin := Vector2.ZERO

## Cell pitch in world units.
var cell_size := 16.0

## Cells per side.
var res := 0

var sea_level := 0.0

## Sampled macro height per cell.
var heights := PackedFloat32Array()

## Heights after depressions are filled. Routing uses these; rendering and
## carving use `heights`, because the filled surface is a routing device and
## not the ground anyone stands on.
var filled := PackedFloat32Array()

## D8 direction index per cell, or SINK.
var flow_dir := PackedByteArray()

## Upslope contributing area per cell, in square metres. The cell's own area
## is included, so a ridge cell reads exactly one cell area.
var accumulation := PackedFloat32Array()

# ── Channels ─────────────────────────────────────────────────────────────────

## Drainage area (m²) at which a cell starts carrying a visible river.
var channel_threshold := 10000.0

## Half-width at exactly `channel_threshold`, in world units.
var width_at_threshold := 1.1

## Hydraulic geometry exponent: half_width scales as area^this. Natural
## channels sit near 0.5 for width against discharge; a little lower keeps
## a 100x catchment from producing a 10x river across a 2 km world.
var width_exponent := 0.34

## Hard ceiling on half-width, so a trunk river near its mouth stays inside
## the valley the carving pass can cut.
var width_max := 4.5

## Extra half-width applied as a channel approaches sea level, which is what
## makes a mouth read as an estuary rather than a pipe that stops.
var estuary_gain := 1.45

## Height above sea level over which `estuary_gain` fades in.
var estuary_height := 6.0

## Depth at `channel_threshold`, and its own (shallower) exponent — a river
## widens faster than it deepens.
var depth_at_threshold := 0.85
var depth_exponent := 0.22
var depth_max := 3.2

## Slope (degrees) at or above which a channel reach is a cascade rather than
## a river. Recorded per point so the mesh builders can treat it differently.
var cascade_slope := 18.0

## Corner-cutting passes applied to every channel, once, for the whole world.
var smooth_passes := 3

## Channel polylines, each an Array of Dictionary points ordered downstream.
## Every channel cell appears in exactly one polyline; a tributary's line
## stops one cell inside its trunk so the two visibly join.
var channels: Array = []

## Diagnostics, printed by the probe and asserted by the tests.
var stats := {}

var _cell_area := 256.0

## Cell indices in the order the priority flood popped them: non-decreasing
## filled height, and every cell after the neighbour it drains to. A
## topological order for the flow graph, for free.
var _pop_order := PackedInt32Array()

## Direction index from each cell back to the neighbour the flood reached it
## from, or SINK for a seed. The routing fallback on flat ground.
var _flood_parent := PackedByteArray()


# ── Build ────────────────────────────────────────────────────────────────────


## Derive the network over a square domain.
##
## `sampler` is called as sampler(world_x, world_z) -> height and must be the
## same macro field the terrain generator uses, or the channels will not sit
## in the valleys the terrain actually has.
func build(sampler: Callable, domain_origin: Vector2, domain_size: float,
		cell: float, sea: float) -> void:
	cell_size = maxf(cell, 1.0)
	res = maxi(int(round(domain_size / cell_size)) + 1, 4)
	origin = domain_origin
	sea_level = sea
	_cell_area = cell_size * cell_size

	var t0 := Time.get_ticks_usec()
	_sample_heights(sampler)
	var t_sample := Time.get_ticks_usec() - t0

	t0 = Time.get_ticks_usec()
	_fill_depressions()
	var t_fill := Time.get_ticks_usec() - t0

	t0 = Time.get_ticks_usec()
	_route()
	var t_route := Time.get_ticks_usec() - t0

	t0 = Time.get_ticks_usec()
	_accumulate()
	var t_accum := Time.get_ticks_usec() - t0

	# river_t is measured against the biggest catchment in the world, so the
	# span has to be known BEFORE any channel point is built.
	var max_area := 0.0
	for i in res * res:
		max_area = maxf(max_area, accumulation[i])
	stats["max_area"] = max_area

	t0 = Time.get_ticks_usec()
	_extract_channels()
	_smooth_channels()
	var t_channels := Time.get_ticks_usec() - t0

	_collect_stats({
		"sample_ms": t_sample / 1000.0,
		"fill_ms": t_fill / 1000.0,
		"route_ms": t_route / 1000.0,
		"accumulate_ms": t_accum / 1000.0,
		"channels_ms": t_channels / 1000.0,
	})


func _sample_heights(sampler: Callable) -> void:
	heights.resize(res * res)
	for gz in res:
		var wz := origin.y + float(gz) * cell_size
		var row := gz * res
		for gx in res:
			heights[row + gx] = sampler.call(origin.x + float(gx) * cell_size, wz)


## Priority-Flood (Barnes, Lehman & Mulla 2014).
##
## Every cell at or below sea level is a seed, along with the domain border, so
## water leaves either into the ocean or off the edge. Depressions between the
## seeds and the interior fill to their spill height.
##
## The flood does double duty. Cells come out of it in non-decreasing filled
## height, and each one is reached FROM an already-drained neighbour — so the
## pop order is a topological order for the drainage graph, and the neighbour a
## cell was reached from is a guaranteed way downhill. Both are recorded here,
## and routing and accumulation use them instead of sorting the lattice again.
##
## The queue is a monotone bucket queue rather than a binary heap: popped
## priorities never decrease during a priority flood, so a rising cursor over
## quantized height buckets is O(n) where a heap is O(n log n).
func _fill_depressions() -> void:
	var count := res * res
	filled = heights.duplicate()
	var visited := PackedByteArray()
	visited.resize(count)
	_pop_order = PackedInt32Array()
	_flood_parent = PackedByteArray()
	_flood_parent.resize(count)
	for i in count:
		_flood_parent[i] = SINK

	var h_min := INF
	var h_max := -INF
	for i in count:
		h_min = minf(h_min, heights[i])
		h_max = maxf(h_max, heights[i])
	# 1 cm buckets. Spill heights come out accurate to one bucket; nothing
	# downstream depends on the pop order being exact (see _accumulate).
	var quantum := 0.01
	var bucket_count := maxi(int((h_max - h_min) / quantum) + 2, 2)
	var buckets: Array = []
	buckets.resize(bucket_count)

	for i in count:
		var gx := i % res
		var gz := i / res
		var is_border := gx == 0 or gz == 0 or gx == res - 1 or gz == res - 1
		if not (is_border or heights[i] <= sea_level):
			continue
		visited[i] = 1
		# Ocean cells are already at their drainage level; the fill must not
		# raise them, so they enter at their own height.
		_bucket_push(buckets, bucket_count, h_min, quantum, i, filled[i])

	var cursor := 0
	while cursor < bucket_count:
		var bucket: Variant = buckets[cursor]
		if bucket == null or (bucket as PackedInt32Array).is_empty():
			cursor += 1
			continue
		var pending: PackedInt32Array = bucket
		buckets[cursor] = PackedInt32Array()
		for c in pending:
			_pop_order.append(c)
			var cgx := c % res
			var cgz := c / res
			var c_filled := filled[c]
			for d in 8:
				var ngx := cgx + DX[d]
				var ngz := cgz + DZ[d]
				if ngx < 0 or ngz < 0 or ngx >= res or ngz >= res:
					continue
				var n := ngz * res + ngx
				if visited[n] == 1:
					continue
				visited[n] = 1
				filled[n] = maxf(heights[n], c_filled)
				# The direction from n back to c. Opposite offsets sit four
				# apart in DX/DZ, so this is the reverse of d.
				_flood_parent[n] = (d + 4) % 8
				_bucket_push(buckets, bucket_count, h_min, quantum, n, filled[n])
		# Re-check this bucket: neighbours can land in it, and must be
		# drained before the cursor moves past their priority.


func _bucket_push(buckets: Array, bucket_count: int, h_min: float,
		quantum: float, index: int, priority: float) -> void:
	var slot := clampi(int((priority - h_min) / quantum), 0, bucket_count - 1)
	if buckets[slot] == null:
		buckets[slot] = PackedInt32Array()
	var bucket: PackedInt32Array = buckets[slot]
	bucket.append(index)
	buckets[slot] = bucket


## D8 steepest descent on the filled surface, falling back to the flood parent
## on ground the fill left dead level.
##
## The fallback is what makes the network actually drain. Steepest descent has
## nowhere to go on a flat, and a flat is exactly what filling a depression
## produces — so a rule that only follows gradient leaves a sink in the middle
## of every filled basin. Measured before the flood parent was used: 22 of 59
## channel heads routed to a cell that was neither ocean nor domain edge, so
## more than a third of the network drained into nothing.
##
## Both edge kinds point strictly earlier in the flood's pop order, so the
## graph stays acyclic and one reverse sweep accumulates it.
func _route() -> void:
	var count := res * res
	flow_dir = PackedByteArray()
	flow_dir.resize(count)
	for i in count:
		var gx := i % res
		var gz := i / res
		# Below sea level, or on the border: this is where water leaves.
		if heights[i] <= sea_level or gx == 0 or gz == 0 or gx == res - 1 or gz == res - 1:
			flow_dir[i] = SINK
			continue
		var best_d := int(SINK)
		var best_gradient := 0.0
		var my_filled := filled[i]
		for d in 8:
			var n := (gz + DZ[d]) * res + gx + DX[d]
			if filled[n] >= my_filled:
				continue
			# Diagonals cover more ground, so compare drop per metre.
			var run := cell_size if (DX[d] == 0 or DZ[d] == 0) else cell_size * 1.41421356
			var gradient := (my_filled - filled[n]) / run
			if gradient > best_gradient:
				best_gradient = gradient
				best_d = d
		flow_dir[i] = best_d if best_d != int(SINK) else _flood_parent[i]


## Accumulate drainage area over the flow graph, in the graph's own
## topological order (Kahn).
##
## The flood's pop order looks like a topological order and is NOT quite one:
## the bucket queue quantizes priorities, so two cells whose filled heights sit
## inside the same bucket can pop in either order, and a flow edge between them
## then points the wrong way through the sweep. Measured: 11 of 16641 edges lost
## their upstream area that way, and because it happens on trunks as readily as
## on headwaters, one of them cut a river mouth from 28504 m2 to 15448 — a
## visible river that abruptly stopped being one.
##
## Counting in-degree costs one extra pass and depends on nothing but the graph,
## so no tie-breaking rule can get it wrong.
func _accumulate() -> void:
	var count := res * res
	accumulation = PackedFloat32Array()
	accumulation.resize(count)
	accumulation.fill(_cell_area)

	var indegree := PackedInt32Array()
	indegree.resize(count)
	for i in count:
		var d := flow_dir[i]
		if d == SINK:
			continue
		indegree[(i / res + DZ[d]) * res + i % res + DX[d]] += 1

	var queue := PackedInt32Array()
	for i in count:
		if indegree[i] == 0:
			queue.append(i)
	var cursor := 0
	var processed := 0
	while cursor < queue.size():
		var i := queue[cursor]
		cursor += 1
		processed += 1
		var d := flow_dir[i]
		if d == SINK:
			continue
		var n := (i / res + DZ[d]) * res + i % res + DX[d]
		accumulation[n] += accumulation[i]
		indegree[n] -= 1
		if indegree[n] == 0:
			queue.append(n)
	# A cell left unprocessed means a cycle in the flow graph, which would
	# silently swallow that catchment's area. Surface it instead.
	stats["unrouted_cells"] = count - processed


# ── Channels ─────────────────────────────────────────────────────────────────


## Walk every channel head downstream, once.
##
## A head is a channel cell with no channel cell flowing into it. Following
## each head to the sea would re-walk every trunk once per tributary, so a
## line stops as soon as it reaches a cell another line already claimed —
## and then takes one more step into it, which is what makes the junction
## visibly join instead of leaving a gap the width of one cell.
func _extract_channels() -> void:
	channels = []
	var count := res * res
	var is_channel := PackedByteArray()
	is_channel.resize(count)
	var inflow := PackedInt32Array()
	inflow.resize(count)
	for i in count:
		if accumulation[i] >= channel_threshold and heights[i] > sea_level:
			is_channel[i] = 1
	for i in count:
		if is_channel[i] == 0:
			continue
		var d := flow_dir[i]
		if d == SINK:
			continue
		var n := (i / res + DZ[d]) * res + i % res + DX[d]
		if is_channel[n] == 1:
			inflow[n] += 1

	var claimed := PackedByteArray()
	claimed.resize(count)
	# Heads first, highest to lowest, so a trunk is claimed by the longest
	# branch above it rather than by whichever tributary happened to be
	# scanned first.
	var heads: Array = []
	for position in range(_pop_order.size() - 1, -1, -1):
		var i := _pop_order[position]
		if is_channel[i] == 1 and inflow[i] == 0:
			heads.append(i)

	for head in heads:
		var line := _walk_downstream(head, is_channel, claimed)
		if line.size() >= 2:
			channels.append(line)


func _walk_downstream(head: int, is_channel: PackedByteArray,
		claimed: PackedByteArray) -> Array:
	var line: Array = []
	var i := head
	var guard := res * 8
	while guard > 0:
		guard -= 1
		line.append(_point(i))
		claimed[i] = 1
		var d := flow_dir[i]
		if d == SINK:
			break
		var n := (i / res + DZ[d]) * res + i % res + DX[d]
		if is_channel[n] == 0:
			# The channel has run out into the sea or off the domain. Take
			# the step anyway: the last point is what puts the mouth in the
			# water rather than one cell short of it.
			line.append(_point(n))
			break
		if claimed[n] == 1:
			# Joining a line that already exists. One step in, then stop.
			line.append(_point(n))
			break
		i = n
	_apply_flow_directions(line)
	return line


## One channel point, in the format the terrain carving and the river renderer
## already consume. `half_width`, `depth` and `cascade` are what replace the
## old "how far has the source dropped" ramp.
func _point(i: int) -> Dictionary:
	var gx := i % res
	var gz := i / res
	var area := accumulation[i]
	var height := heights[i]
	return {
		"world_x": origin.x + float(gx) * cell_size,
		"world_z": origin.y + float(gz) * cell_size,
		"surface_y": height,
		"drainage_area": area,
		"half_width": half_width_for(area, height),
		"depth": depth_for(area),
		"river_t": river_t_for(area),
		"flow_dir_x": 0.0,
		"flow_dir_z": 1.0,
		"cascade": false,
	}


## Fill in per-point flow direction and mark cascade reaches.
func _apply_flow_directions(line: Array) -> void:
	for i in line.size():
		var point: Dictionary = line[i]
		var a: Dictionary = line[maxi(i - 1, 0)]
		var b: Dictionary = line[mini(i + 1, line.size() - 1)]
		var dir := Vector2(float(b["world_x"]) - float(a["world_x"]),
			float(b["world_z"]) - float(a["world_z"]))
		if dir.length_squared() > 0.000001:
			dir = dir.normalized()
			point["flow_dir_x"] = dir.x
			point["flow_dir_z"] = dir.y
		if i < line.size() - 1:
			var next: Dictionary = line[i + 1]
			var run := Vector2(float(next["world_x"]) - float(point["world_x"]),
				float(next["world_z"]) - float(point["world_z"])).length()
			var drop := float(point["surface_y"]) - float(next["surface_y"])
			if run > 0.001:
				point["slope_degrees"] = rad_to_deg(atan(maxf(drop, 0.0) / run))
				point["cascade"] = float(point["slope_degrees"]) >= cascade_slope
			else:
				point["slope_degrees"] = 0.0
		else:
			point["slope_degrees"] = float(line[maxi(i - 1, 0)].get("slope_degrees", 0.0))
			point["cascade"] = bool(line[maxi(i - 1, 0)].get("cascade", false))
		line[i] = point


# ── Smoothing ────────────────────────────────────────────────────────────────


## Smooth and densify every channel, ONCE, for the whole world.
##
## This cannot be a per-chunk step. The routing lattice is coarser than a
## chunk — at the defaults a chunk is 32 m and a cell is 16 m — so a chunk
## holds two or three channel points, and each chunk smoothing its own subset
## would put a different curve on each side of every seam. Smoothing the whole
## channel first and letting chunks clip the result is what keeps a riverbed
## continuous across a boundary.
func _smooth_channels() -> void:
	var spacing := clampf(cell_size * 0.25, 1.0, 4.0)
	var out: Array = []
	for line in channels:
		var smoothed := _chaikin(line, smooth_passes)
		var dense := _resample(smoothed, spacing)
		if dense.size() < 2:
			continue
		_enforce_descent(dense)
		_apply_flow_directions(dense)
		out.append(dense)
	channels = out


## Force the channel's surface profile to run downhill.
##
## Two things put uphill steps in a raw profile, and both are legitimate. A
## corner-cutting pass moves the line off the exact lattice path, and the
## corner it cuts can be higher ground; and a channel crossing a filled
## depression runs over terrain that genuinely rises, because the depression
## is a lake. Either way the water surface does not climb, so the profile is
## clamped and the carving pass digs the difference out. Measured on the raw
## profile: 24-30% of downstream steps rose.
func _enforce_descent(line: Array) -> void:
	var last := INF
	for i in line.size():
		var point: Dictionary = line[i]
		var y := minf(float(point["surface_y"]), last)
		last = y
		point["surface_y"] = y
		line[i] = point


## Chaikin corner cutting with the endpoints pinned.
##
## Attributes are interpolated along with the positions. A pass that moved
## geometry but not width would put a wide point on a narrow reach — and the
## carving pass reads width per point.
func _chaikin(line: Array, passes: int) -> Array:
	var current := line
	for _pass in maxi(passes, 0):
		if current.size() < 3:
			break
		var next: Array = [current[0]]
		for i in range(current.size() - 1):
			next.append(_lerp_point(current[i], current[i + 1], 0.25))
			next.append(_lerp_point(current[i], current[i + 1], 0.75))
		next.append(current[current.size() - 1])
		current = next
	return current


## Even spacing along the polyline, so carving gets a point per cell it has to
## dig rather than a point per lattice step.
func _resample(line: Array, spacing: float) -> Array:
	if line.size() < 2:
		return line.duplicate()
	var out: Array = [line[0]]
	var carry := 0.0
	for i in range(line.size() - 1):
		var a: Dictionary = line[i]
		var b: Dictionary = line[i + 1]
		var seg := Vector2(float(b["world_x"]) - float(a["world_x"]),
			float(b["world_z"]) - float(a["world_z"])).length()
		if seg < 0.0001:
			continue
		var travelled := spacing - carry
		while travelled < seg:
			out.append(_lerp_point(a, b, travelled / seg))
			travelled += spacing
		carry = seg - (travelled - spacing)
	out.append(line[line.size() - 1])
	return out


func _lerp_point(a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	return {
		"world_x": lerpf(float(a["world_x"]), float(b["world_x"]), t),
		"world_z": lerpf(float(a["world_z"]), float(b["world_z"]), t),
		"surface_y": lerpf(float(a["surface_y"]), float(b["surface_y"]), t),
		"drainage_area": lerpf(float(a["drainage_area"]), float(b["drainage_area"]), t),
		"half_width": lerpf(float(a["half_width"]), float(b["half_width"]), t),
		"depth": lerpf(float(a["depth"]), float(b["depth"]), t),
		"river_t": lerpf(float(a["river_t"]), float(b["river_t"]), t),
		"slope_degrees": lerpf(float(a.get("slope_degrees", 0.0)),
			float(b.get("slope_degrees", 0.0)), t),
		"cascade": bool(a.get("cascade", false)) if t < 0.5 else bool(b.get("cascade", false)),
		"flow_dir_x": float(a["flow_dir_x"]),
		"flow_dir_z": float(a["flow_dir_z"]),
	}


# ── Hydraulic geometry ───────────────────────────────────────────────────────


## Half-width from drainage area, widened toward the mouth.
##
## Downstream hydraulic geometry: channel width goes as a power of discharge,
## and discharge goes as catchment area. That single relation is what the old
## code was reaching for with a width ramp keyed on elevation drop — which
## made a short steep stream that fell 40 m wider than a long trunk that fell
## 20, exactly backwards.
func half_width_for(area: float, height: float) -> float:
	if area < channel_threshold:
		return 0.0
	var ratio := area / channel_threshold
	var half := width_at_threshold * pow(ratio, width_exponent)
	# Estuary: a mouth spreads as it meets standing water. Fades in over the
	# last few metres of elevation rather than at a fixed distance, so it
	# tracks the actual shoreline.
	var mouth_t := clampf(1.0 - (height - sea_level) / maxf(estuary_height, 0.001), 0.0, 1.0)
	half *= lerpf(1.0, estuary_gain, mouth_t * mouth_t)
	return minf(half, width_max)


func depth_for(area: float) -> float:
	if area < channel_threshold:
		return 0.0
	return minf(depth_at_threshold * pow(area / channel_threshold, depth_exponent), depth_max)


## Normalized "how big is this river", 0 at the smallest channel and 1 at the
## widest the world produces. Kept because the carving and the water shader
## both key their blends on it.
func river_t_for(area: float) -> float:
	if area < channel_threshold:
		return 0.0
	var span := maxf(float(stats.get("max_area", channel_threshold * 64.0)), channel_threshold * 2.0)
	return clampf(log(area / channel_threshold) / log(span / channel_threshold), 0.0, 1.0)


# ── Queries ──────────────────────────────────────────────────────────────────


func contains(wx: float, wz: float) -> bool:
	var span := float(res - 1) * cell_size
	return wx >= origin.x and wz >= origin.y \
		and wx <= origin.x + span and wz <= origin.y + span


## Drainage area at a world position, bilinearly interpolated. 0 outside the
## domain — a caller must treat that as "no hydrology here", not as a ridge.
func area_at(wx: float, wz: float) -> float:
	if not contains(wx, wz):
		return 0.0
	var fx := clampf((wx - origin.x) / cell_size, 0.0, float(res - 1))
	var fz := clampf((wz - origin.y) / cell_size, 0.0, float(res - 1))
	var gx0 := mini(int(fx), res - 2)
	var gz0 := mini(int(fz), res - 2)
	var tx := fx - float(gx0)
	var tz := fz - float(gz0)
	var a00 := accumulation[gz0 * res + gx0]
	var a10 := accumulation[gz0 * res + gx0 + 1]
	var a01 := accumulation[(gz0 + 1) * res + gx0]
	var a11 := accumulation[(gz0 + 1) * res + gx0 + 1]
	return lerpf(lerpf(a00, a10, tx), lerpf(a01, a11, tx), tz)


## Bucket every channel point into the chunk grid, once.
##
## Without this, each chunk walks every point of every channel in the world to
## find the handful that touch it. There are tens of thousands of points after
## densification and a streaming session loads hundreds of chunks, so the
## per-chunk clip is the difference between an index lookup and a full sweep.
##
## `margin` widens each bucket so a segment entering from outside is included:
## the carving pass needs it, or every chunk boundary gets a step in the bed.
func index_chunks(chunk_size: float, margin: float) -> void:
	_chunk_index = {}
	_indexed_chunk_size = maxf(chunk_size, 1.0)
	var reach := int(ceil(margin / _indexed_chunk_size))
	for line_id in channels.size():
		var line: Array = channels[line_id]
		# Which chunks this line's points fall in, plus their neighbourhood.
		var touched: Dictionary = {}
		for point in line:
			var cx := floori(float(point["world_x"]) / _indexed_chunk_size)
			var cz := floori(float(point["world_z"]) / _indexed_chunk_size)
			for dz in range(-reach, reach + 1):
				for dx in range(-reach, reach + 1):
					touched[Vector2i(cx + dx, cz + dz)] = true
		for coord in touched:
			if not _chunk_index.has(coord):
				_chunk_index[coord] = PackedInt32Array()
			var ids: PackedInt32Array = _chunk_index[coord]
			ids.append(line_id)
			_chunk_index[coord] = ids


## Channel polylines that touch one chunk, clipped to it plus a margin.
func channels_for_chunk(chunk_origin: Vector2, chunk_size: float,
		margin: float) -> Array:
	var min_x := chunk_origin.x - margin
	var max_x := chunk_origin.x + chunk_size + margin
	var min_z := chunk_origin.y - margin
	var max_z := chunk_origin.y + chunk_size + margin
	var candidates: Array = []
	if _chunk_index.is_empty():
		candidates = channels
	else:
		var coord := Vector2i(floori(chunk_origin.x / _indexed_chunk_size),
			floori(chunk_origin.y / _indexed_chunk_size))
		if not _chunk_index.has(coord):
			return []
		for line_id in _chunk_index[coord] as PackedInt32Array:
			candidates.append(channels[line_id])
	var out: Array = []
	for line in candidates:
		var run: Array = []
		for point in line:
			var px := float(point["world_x"])
			var pz := float(point["world_z"])
			var inside := px >= min_x and px <= max_x and pz >= min_z and pz <= max_z
			if inside:
				run.append(point)
			elif not run.is_empty():
				# Keep the first point past the edge so the segment reaches
				# it, then start a new run if the line comes back.
				run.append(point)
				if run.size() >= 2:
					out.append(run)
				run = []
		if run.size() >= 2:
			out.append(run)
	return out


## chunk coord -> ids of the channels that touch it.
var _chunk_index: Dictionary = {}
var _indexed_chunk_size := 32.0


func _collect_stats(timings: Dictionary) -> void:
	var count := res * res
	var max_area := float(stats.get("max_area", 0.0))
	var unrouted := int(stats.get("unrouted_cells", 0))
	var channel_cells := 0
	var land_cells := 0
	var filled_cells := 0
	for i in count:
		max_area = maxf(max_area, accumulation[i])
		if heights[i] > sea_level:
			land_cells += 1
			if accumulation[i] >= channel_threshold:
				channel_cells += 1
		if filled[i] > heights[i] + 0.01:
			filled_cells += 1
	var reached_sea := 0
	var cascade_points := 0
	var total_points := 0
	for line in channels:
		var last: Dictionary = line[line.size() - 1]
		if float(last["surface_y"]) <= sea_level + 0.5:
			reached_sea += 1
		for point in line:
			total_points += 1
			if bool(point.get("cascade", false)):
				cascade_points += 1
	stats = timings.duplicate()
	stats["cells"] = count
	stats["res"] = res
	stats["cell_size"] = cell_size
	stats["land_cells"] = land_cells
	stats["depression_cells"] = filled_cells
	stats["max_area"] = max_area
	stats["channel_cells"] = channel_cells
	stats["channels"] = channels.size()
	stats["channel_points"] = total_points
	stats["cascade_points"] = cascade_points
	stats["mouths_at_sea"] = reached_sea
	stats["unrouted_cells"] = unrouted
