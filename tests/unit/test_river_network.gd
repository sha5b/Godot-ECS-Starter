extends EcsTestCase

## Unit tests for the drainage network: routing, depression filling, area
## conservation, and the hydraulic geometry derived from drainage area.
##
## RiverNetwork takes a height sampler and returns data, so these run on
## synthetic terrain where the right answer is known exactly — an inclined
## plane drains a known amount through every row, and a plane with a pit in it
## must still drain all of it.

const DOMAIN := 512.0
const CELL := 16.0


## A valley running down toward +z: a V cross-section on a slope.
##
## A uniform plane would not do. Flow on a plane never converges, so every cell
## carries one column's worth of area and there is no channel anywhere — which
## is correct hydrology and a useless fixture. A valley makes the water gather
## into a trunk, which is what the network is for.
func _valley(wx: float, wz: float) -> float:
	return 18.0 - wz * 0.05 + absf(wx - DOMAIN * 0.5) * 0.04


## The same valley with a closed pit in it, above sea level so the fill has to
## deal with it rather than treating it as ocean.
func _valley_with_pit(wx: float, wz: float) -> float:
	var h := _valley(wx, wz)
	var to_centre := Vector2(wx - DOMAIN * 0.5, wz - 200.0).length()
	if to_centre < 60.0:
		h -= 5.0 * (1.0 - to_centre / 60.0)
	return h


func _build(sampler: Callable) -> RiverNetwork:
	var network := RiverNetwork.new()
	network.channel_threshold = 4000.0
	network.build(sampler, Vector2.ZERO, DOMAIN, CELL, 0.0)
	return network


func test_every_cell_is_routed() -> void:
	var network := _build(_valley)
	assert_equal(network.stats["unrouted_cells"], 0,
		"a cycle in the flow graph would swallow a whole catchment")


## Every cell's area must arrive at exactly one sink, so the areas summed over
## the sinks must equal the whole lattice. This is the single strongest check
## on routing: it fails if any cell drains nowhere, drains twice, or loops.
func test_drainage_area_is_conserved() -> void:
	var network := _build(_valley)
	var total := 0.0
	for i in network.res * network.res:
		if network.flow_dir[i] == RiverNetwork.SINK:
			total += network.accumulation[i]
	var expected := float(network.res * network.res) * CELL * CELL
	# float32 accumulation over ~400 cells per sink; a metre of slack.
	assert_almost(total, expected, 1.0,
		"area summed over sinks must equal the lattice area")


## Water gathers as it goes. Row by row down the valley the total area passing
## through must grow.
func test_area_grows_downslope() -> void:
	var network := _build(_valley)
	var res: int = network.res
	var previous := 0.0
	var rows_checked := 0
	# Skip the border rows: they are sinks by definition.
	for gz in range(1, res - 1):
		var row_total := 0.0
		for gx in range(1, res - 1):
			row_total += network.accumulation[gz * res + gx]
		# Stop at the row where the valley FLOOR reaches the sea, not where its
		# flanks do: once the trunk drains out of the lattice the rows below it
		# carry only their own slopes, and legitimately carry less.
		if network.heights[gz * res + res / 2] <= 0.0:
			break
		assert_true(row_total > previous,
			"row %d carries %.0f, the row above carried %.0f" % [gz, row_total, previous])
		previous = row_total
		rows_checked += 1
	assert_true(rows_checked > 4, "expected several land rows, got %d" % rows_checked)


## A pit is a place a "flow to the lowest neighbour" rule stops dead. After
## depression filling, nothing inland may be a sink.
func test_pits_do_not_trap_water() -> void:
	var network := _build(_valley_with_pit)
	var res: int = network.res
	var inland_sinks := 0
	for i in res * res:
		var gx := i % res
		var gz := i / res
		if gx == 0 or gz == 0 or gx == res - 1 or gz == res - 1:
			continue
		if network.heights[i] <= 0.0:
			continue
		if network.flow_dir[i] == RiverNetwork.SINK:
			inland_sinks += 1
	assert_equal(inland_sinks, 0, "land above sea must always have a way downhill")
	assert_true(network.stats["depression_cells"] > 0,
		"the pit should have been filled, so some cells sit above their ground")


## Following the flow graph from anywhere must terminate at the ocean or at the
## edge of the domain — never in a loop, never in a hole.
func test_flow_always_reaches_an_outlet() -> void:
	var network := _build(_valley_with_pit)
	var res: int = network.res
	var checked := 0
	for start in range(0, res * res, 3):
		var i := start
		var guard := res * res
		while network.flow_dir[i] != RiverNetwork.SINK and guard > 0:
			guard -= 1
			var d: int = network.flow_dir[i]
			i = (i / res + RiverNetwork.DZ[d]) * res + i % res + RiverNetwork.DX[d]
		assert_true(guard > 0, "walk from cell %d never terminated" % start)
		var gx := i % res
		var gz := i / res
		var is_outlet := network.heights[i] <= 0.0 \
			or gx == 0 or gz == 0 or gx == res - 1 or gz == res - 1
		assert_true(is_outlet, "walk from cell %d stopped inland at %d" % [start, i])
		checked += 1
	assert_true(checked > 200, "expected to sample many starts, got %d" % checked)


## Channels only exist where enough land drains through, and a channel point
## always carries a width.
func test_channels_only_where_water_collects() -> void:
	var network := _build(_valley)
	assert_true(network.channels.size() > 0, "a valley this size should carry a channel")
	for line in network.channels:
		for point in line:
			assert_true(float(point["half_width"]) > 0.0,
				"channel point with no width at (%.0f, %.0f)"
					% [float(point["world_x"]), float(point["world_z"])])


## Hydraulic geometry: more catchment is never a narrower river. This is the
## property the old elevation-drop width ramp did not have — a short steep
## stream came out wider than a long trunk.
func test_width_grows_with_drainage_area() -> void:
	var network := RiverNetwork.new()
	network.channel_threshold = 10000.0
	network.width_at_threshold = 1.5
	network.width_max = 4.5
	network.sea_level = 0.0
	var last := 0.0
	for multiple in [1.0, 2.0, 4.0, 8.0, 16.0, 64.0]:
		var half: float = network.half_width_for(network.channel_threshold * multiple, 30.0)
		assert_true(half >= last, "%.1fx the catchment gave %.2f m, less than %.2f m"
			% [multiple, half, last])
		last = half
	assert_true(last <= network.width_max, "half-width must respect its ceiling")
	assert_almost(network.half_width_for(network.channel_threshold * 0.99, 30.0), 0.0,
		0.0001, "below the threshold there is no channel")


## A mouth spreads. Same catchment, at sea level instead of up the hill, must
## be wider — that is the estuary, and it replaces an alpha fade.
func test_mouths_widen_into_an_estuary() -> void:
	var network := RiverNetwork.new()
	network.channel_threshold = 10000.0
	network.width_at_threshold = 1.5
	network.width_max = 99.0
	network.estuary_gain = 1.45
	network.estuary_height = 6.0
	network.sea_level = 0.0
	var area := 40000.0
	var inland := network.half_width_for(area, 30.0)
	var at_mouth := network.half_width_for(area, 0.0)
	assert_true(at_mouth > inland * 1.3,
		"mouth %.2f m vs inland %.2f m — the estuary did not open" % [at_mouth, inland])


## Depth grows more slowly than width: a river spreads out faster than it digs
## in. Equal exponents would make depth a second reading of width.
func test_depth_grows_slower_than_width() -> void:
	var network := RiverNetwork.new()
	network.channel_threshold = 10000.0
	network.width_at_threshold = 1.5
	network.depth_at_threshold = 0.85
	network.width_max = 99.0
	network.depth_max = 99.0
	var area := network.channel_threshold * 32.0
	var width_ratio := network.half_width_for(area, 30.0) / network.width_at_threshold
	var depth_ratio := network.depth_for(area) / network.depth_at_threshold
	assert_true(width_ratio > depth_ratio,
		"width grew %.2fx and depth %.2fx" % [width_ratio, depth_ratio])


## Water does not climb. After smoothing cuts corners, the surface profile
## along a channel must still run downhill.
func test_channel_profiles_run_downhill() -> void:
	var network := _build(_valley_with_pit)
	var rises := 0
	var steps := 0
	for line in network.channels:
		for i in range(line.size() - 1):
			steps += 1
			if float(line[i + 1]["surface_y"]) > float(line[i]["surface_y"]) + 0.001:
				rises += 1
	assert_true(steps > 0, "expected channel points to compare")
	assert_equal(rises, 0, "%d of %d downstream steps went uphill" % [rises, steps])


## Drainage area never shrinks downstream along a channel either — that is what
## makes a confluence widen the trunk instead of resetting it.
func test_channel_area_never_shrinks_downstream() -> void:
	var network := _build(_valley_with_pit)
	for line in network.channels:
		for i in range(line.size() - 1):
			var here := float(line[i]["drainage_area"])
			var below := float(line[i + 1]["drainage_area"])
			# Smoothing interpolates between lattice points, so allow a
			# fraction of a percent of interpolation noise.
			assert_true(below >= here * 0.99,
				"area fell from %.0f to %.0f m^2 going downstream" % [here, below])


## The per-chunk index must return the same segments a full sweep would.
func test_chunk_index_matches_a_full_sweep() -> void:
	var network := _build(_valley)
	var chunk_size := 32.0
	var margin: float = network.cell_size * 2.0
	# Snapshot the un-indexed answer first.
	var without: Array = []
	for coord in [Vector2i(2, 2), Vector2i(4, 6), Vector2i(0, 9)]:
		var origin := Vector2(coord.x * chunk_size, coord.y * chunk_size)
		without.append(network.channels_for_chunk(origin, chunk_size, margin).size())
	network.index_chunks(chunk_size, margin)
	var index := 0
	for coord in [Vector2i(2, 2), Vector2i(4, 6), Vector2i(0, 9)]:
		var origin := Vector2(coord.x * chunk_size, coord.y * chunk_size)
		var indexed := network.channels_for_chunk(origin, chunk_size, margin).size()
		assert_equal(indexed, without[index],
			"chunk %s: indexed %d segments, full sweep found %d"
				% [str(coord), indexed, without[index]])
		index += 1
