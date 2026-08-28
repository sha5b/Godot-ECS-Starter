class_name TerrainConfig
extends Node

## Configuration component for the TerrainSystem.
## Tweak all values in the Inspector — no code changes needed.

@export_group("Mesh")
## Resolution of the heightmap grid per chunk (e.g. 32 = 32x32 vertices)
@export var chunk_resolution: int = 33

## Width (in vertices) of the chunk-border blend zone. Erosion is chunk-local,
## so heights are blended back to pristine values near borders: exact match
## at the seam, smooth transition into the eroded interior. Without this,
## hard-restored border rings meet eroded interiors in visible cliff cuts.
@export_range(2, 12) var border_blend_cells: int = 6

@export_group("Seed Variation")
## How much the seed may change the world's RECIPE, not just the arrangement of
## its noise.
##
## Every noise layer was already keyed on the seed, so each start produced
## different terrain — but land fraction, relief, mountain coverage and island
## scale were fixed, so it was always the same kind of place. This dial lets
## the seed roll those too: 0 reproduces the values below exactly, 1 gives the
## full spread. See systems/terrain/world_variation.gd for the ranges.
##
## The values in this inspector stay the BASELINE the roll is centred on; they
## are never overwritten on disk.
@export_range(0.0, 1.0) var seed_variation: float = 0.85

@export_group("Height")
## Vertical scale multiplier for terrain height
@export var height_scale: float = 35.0

## Sea level — anything below this is underwater
@export var sea_level: float = 0.0

## How much to flatten terrain near sea level (0 = none, 1 = full)
@export_range(0.0, 1.0) var coastal_flattening: float = 0.25

## Exponent applied to land elevation. Summed noise is symmetric, which puts
## as much terrain high as low and reads as rolling hills everywhere. An
## exponent above 1 makes low ground common and high ground rare, which is
## what real elevation histograms look like.
@export_range(1.0, 4.0) var land_elevation_power: float = 1.8

@export_group("Continent Noise")
## Very low frequency noise shaping continents/islands
@export var continent_frequency: float = 0.0015

## Octaves of the continent field.
##
## This used to be unset, which meant FastNoiseLite's default of 5 FBM
## octaves: the top octave landed at ~0.024, FINER than the detail layer,
## so the "continent" field was really a second detail layer and the world
## had no continent-scale structure at all. Keep this at 1-2.
@export_range(1, 4) var continent_octaves: int = 2

## Continent noise contribution (blended with detail noise)
@export_range(0.0, 1.0) var continent_weight: float = 0.5

## Fraction of the world above sea level. The sea threshold is solved from
## the continent field at startup, so this value means what it says.
@export_range(0.05, 0.95) var continent_land_fraction: float = 0.38

## Width of the coastal ramp, in continent-noise units. Wider = broader
## continental shelves and gentler coasts.
@export_range(0.02, 0.6) var continent_shelf_width: float = 0.16

@export_group("Mountain Belts")
## Confine ridged mountains to orogeny belts instead of raising them evenly
## across every landmass. Real ranges are long curved chains along plate
## margins; scattering ridge noise over all land is what makes terrain read
## as uniform lumpy hills with no skyline.
@export var orogeny_enabled: bool = true

## Frequency of the belt field. Lower = longer, wider-spaced ranges.
@export var orogeny_frequency: float = 0.0009

## Fraction of the belt field's range counted as "inside a belt".
@export_range(0.05, 1.0) var orogeny_coverage: float = 0.34

## Exponent on the belt mask. Higher = narrower spines with steeper flanks.
@export_range(1.0, 8.0) var orogeny_belt_sharpness: float = 2.6

@export_group("Detail Noise")
## Detail noise frequency — higher = more bumpy small features
@export var noise_frequency: float = 0.012

## Number of noise octaves for detail layering
@export_range(1, 8) var octaves: int = 5

## Lacunarity — frequency multiplier per octave
@export var lacunarity: float = 2.2

## Persistence — amplitude multiplier per octave
@export var persistence: float = 0.5

@export_group("Ridged Noise")
## Enable ridged multifractal for mountain spines and sharp ridgelines
@export var ridged_enabled: bool = true

## Frequency of the ridged noise layer
@export var ridged_frequency: float = 0.005

## Number of octaves for ridged noise
@export_range(1, 8) var ridged_octaves: int = 4

## Lacunarity for ridged noise
@export var ridged_lacunarity: float = 2.0

## Ridged noise contribution weight. This is the height of a range crest as
## a fraction of height_scale, ON TOP of the land base — so peaks inside a
## belt reach past height_scale while the plains around them stay low.
@export_range(0.0, 1.5) var ridged_weight: float = 0.78

## Exponent applied to ridged noise to sharpen peaks (higher = sharper)
@export_range(0.5, 4.0) var ridged_power: float = 1.8

@export_group("Domain Warping")
## Enable domain warping for tectonic-style terrain distortion
@export var warp_enabled: bool = true

## Strength of domain warp displacement in world units
@export var warp_strength: float = 55.0

## Frequency of the warp noise
@export var warp_frequency: float = 0.002

@export_group("Valley & Plateau")
## Enable valley carving pass that deepens drainage channels
@export var valley_carving_enabled: bool = true

## Noise frequency for valley detection mask
@export var valley_frequency: float = 0.003

## How deep valleys are carved (multiplier on height reduction)
@export_range(0.0, 1.0) var valley_depth: float = 0.5

## Enable plateau flattening at mid-high elevations
@export var plateau_enabled: bool = true

## Threshold above which terrain flattens into plateaus (normalized 0-1)
@export_range(0.0, 1.0) var plateau_threshold: float = 0.55

## How aggressively plateaus flatten (0 = none, 1 = completely flat)
@export_range(0.0, 1.0) var plateau_strength: float = 0.25

@export_group("Walkability")
## Target maximum walkable slope (degrees) — terrain tries to keep traversal corridors below this
@export_range(10.0, 60.0) var max_walkable_slope: float = 40.0

## Fraction of terrain forced below walkable slope (0 = no enforcement)
@export_range(0.0, 1.0) var walkable_enforcement: float = 0.3

## Normalized elevation above which walkability enforcement is skipped, so
## high mountains stay unclimbably steep instead of being graded into ramps.
@export_range(0.0, 1.0) var walkable_max_normalized_height: float = 0.55

@export_group("Traversal")
@export var traversal_enabled: bool = true

@export var traversal_corridor_frequency: float = 0.006

@export var traversal_corridor_width: float = 4.5

@export_range(0.0, 1.0) var traversal_corridor_strength: float = 0.38

@export_range(0.0, 1.0) var plateau_access_strength: float = 0.34

@export_range(0.0, 1.0) var plateau_access_threshold: float = 0.72

@export_range(0.0, 1.0) var ridge_pass_strength: float = 0.28

@export_range(15.0, 75.0) var traversal_cliff_slope: float = 52.0

@export_group("Shoreline")
## Width of the smooth beach gradient (world units from sea level)
@export var beach_width: float = 3.0

## How gradually the beach slopes into water (higher = more gradual)
@export_range(1.0, 5.0) var beach_slope_power: float = 2.0

## Extra noise on the shoreline to break up straight edges
@export var shoreline_noise_strength: float = 1.5

## Frequency of shoreline irregularity noise
@export var shoreline_noise_frequency: float = 0.03

@export_group("Ocean Floor")
## Enable detailed ocean floor shaping with depth zones
@export var ocean_floor_enabled: bool = true

## Continental shelf depth below sea level (shallow near-shore zone)
@export var shelf_depth: float = 3.0

## Continental shelf width as fraction of chunk (how far shelf extends)
@export_range(0.0, 1.0) var shelf_width_factor: float = 0.3

## Continental slope depth (transition from shelf to deep ocean)
@export var slope_depth: float = 10.0

## Abyss depth (deepest ocean floor)
@export var abyss_depth: float = 15.0

## Seafloor detail noise frequency — adds ridges, trenches, seamounts
@export var seafloor_noise_frequency: float = 0.015

## Seafloor detail noise amplitude (world units)
@export var seafloor_noise_amplitude: float = 2.5

## Seafloor large-scale variation frequency (underwater hills/valleys)
@export var seafloor_macro_frequency: float = 0.003

## Seafloor large-scale variation amplitude
@export var seafloor_macro_amplitude: float = 4.0

@export_group("Voxel Grid")
## Number of vertical layers in the density grid (Y resolution)
@export_range(8, 64) var vertical_resolution: int = 54

## Lowest Y value of the density grid (world units)
@export var grid_min_y: float = -30.0

## Highest Y value of the density grid (world units).
## Must clear the tallest peak height_scale can produce, or summits are
## sliced flat by the top of the density volume.
@export var grid_max_y: float = 48.0

## Density threshold for surface extraction (iso-level)
@export_range(-1.0, 1.0) var surface_threshold: float = 0.0

@export_group("Adaptive Detail")
@export var adaptive_refinement_enabled: bool = true

@export_range(1, 2) var adaptive_refine_subdivisions: int = 2

@export_range(5.0, 80.0) var adaptive_cliff_slope_threshold: float = 34.0

@export var adaptive_shore_band: float = 2.2

@export var adaptive_river_band_multiplier: float = 1.35

@export_group("Caves")
## Enable cave generation in the density field
@export var caves_enabled: bool = true

## Frequency of spaghetti cave noise (winding tunnels)
@export var cave_spaghetti_freq: float = 0.04

## Threshold for spaghetti caves — lower = wider tunnels
@export_range(0.0, 0.5) var cave_spaghetti_threshold: float = 0.23

## Frequency of cheese cave noise (large open caverns)
@export var cave_cheese_freq: float = 0.015

## Threshold for cheese caves — lower = larger caverns
@export_range(0.0, 0.8) var cave_cheese_threshold: float = 0.38

## Minimum depth below surface for caves to start (world units)
@export var cave_min_depth: float = 4.0

## Maximum depth for cave generation (world units below sea level)
@export var cave_max_depth: float = 25.0

## Minimum density value for cave carving to activate (lower = carves thinner rock)
@export var cave_density_threshold: float = 1.2

## Minimum height above sea level for caves to form (world units)
@export var cave_sea_buffer: float = 1.0

## Transition distance for cave fade-in/fade-out (world units)
@export var cave_depth_ramp: float = 3.0

## Spaghetti cave carving strength (lower = subtler tunnels)
@export var cave_spaghetti_strength: float = 2.9

## Cheese cave carving strength (lower = subtler caverns)
@export var cave_cheese_strength: float = 2.35

## Density-to-carving scale multiplier (how density maps to carving force)
@export var cave_carve_multiplier: float = 0.36

## Minimum carving scale factor
@export var cave_carve_min: float = 1.0

## Maximum carving scale factor (caps deep-terrain amplification)
@export var cave_carve_max: float = 3.0

@export var cave_min_region_voxels: int = 18


@export_range(0.0, 89.0) var cave_entrance_preferred_slope: float = 18.0

@export var cave_entrance_floor_clearance: float = 2.4

@export_subgroup("Cave Entrances")
## Enable automatic cave entrance carving from surface to nearest cave
@export var cave_entrances_enabled: bool = true

## World-unit radius of the entrance opening
@export var cave_entrance_radius: float = 4.8

## Noise threshold for entrance placement (higher = fewer entrances)
@export_range(0.0, 1.0) var cave_entrance_threshold: float = 0.22

## How steep the entrance tunnel slopes (higher = steeper)
@export var cave_entrance_slope: float = 3.2

## Noise frequency for entrance placement (lower = larger clusters)
@export var cave_entrance_noise_freq: float = 0.02

## Cave wall color (vertex colored)
@export var cave_wall_color: Color = Color(0.30, 0.28, 0.25)

## Cave color variation
@export_range(0.0, 0.2) var cave_color_variation: float = 0.06

@export_group("Rivers")
## Enable river channel carving in the density field
@export var rivers_enabled: bool = true

@export_subgroup("Hydrology")
## Rivers are derived from flow accumulation over the macro height field:
## how much land drains through a place decides whether it has a channel and
## how big that channel is. Width, depth, tributary merging and reaching the
## sea all come from that one quantity — see systems/terrain/river_network.gd.

## Side length of the square the drainage network is computed over, in world
## units, centred on the origin.
##
## 0 means derive it from the world: world_size_chunks x chunk_size. Set it
## explicitly only to compute hydrology over a different extent than the world
## claims to be — outside the domain there are no rivers, because there is no
## catchment to derive them from.
@export var river_domain_size: float = 0.0

## Cell pitch of the routing lattice. Cost is quadratic in this: halving it
## quadruples both the height samples and the sort. 16 m resolves the valleys
## the macro field actually has, and channel polylines are smoothed and
## resampled before carving, so the lattice is not what you see.
@export_range(4.0, 64.0) var river_flow_cell_size: float = 16.0

## Drainage area (m²) at which a cell starts carrying a visible channel.
## This is the single dial for "how many rivers": lower means the network
## reaches further up into the headwaters.
@export var river_channel_threshold_area: float = 10000.0

## Half-width scales as drainage_area^this. Natural channels sit near 0.5 of
## discharge; lower keeps a 100x catchment from making a 10x river.
@export_range(0.1, 0.6) var river_width_exponent: float = 0.34

## Hard ceiling on channel half-width (world units).
@export var river_width_max: float = 4.5

## How much wider a channel gets as it meets the sea. This is what makes a
## mouth read as an estuary instead of a pipe that stops.
@export_range(1.0, 4.0) var river_estuary_gain: float = 1.45

## Elevation above sea level over which the estuary widening fades in.
@export var river_estuary_height: float = 6.0

## Channel slope (degrees) at or above which a reach is a cascade rather than
## a river. Recorded per channel point.
@export_range(10.0, 60.0) var river_cascade_slope: float = 18.0

@export_subgroup("Path")
## Whether steep-slope river tracing can sample diagonal/extended neighbors
@export var river_allow_diagonal_descent: bool = true

## Additional search radius for river descent on steep terrain (1 = immediate neighbors only)
@export_range(1, 2) var river_descent_neighbor_radius: int = 2

## Path smoothing passes applied to channel polylines before carving. The
## routing lattice is coarse and its steps are 45-degree, so without this a
## riverbed has visible corners.
@export_range(0, 10) var river_smooth_passes: int = 3

## River channel half-width at exactly river_channel_threshold_area, in world
## units. Everything wider than this comes from drainage area.
@export var river_width_start: float = 1.5

## How deep the river channel is carved (world units)
@export var river_carve_depth: float = 1.35

## Falloff steepness for channel edges (higher = sharper banks)
@export_range(1.0, 8.0) var river_carve_falloff: float = 1.35

@export_range(0.1, 0.9) var river_channel_core_ratio: float = 0.40

@export var river_bank_width_multiplier: float = 2.2

@export var river_valley_width_multiplier: float = 3.6

@export var river_valley_depth_multiplier: float = 0.24

@export_range(0.5, 4.0) var river_valley_profile_power: float = 1.2

@export var river_bank_clearance_height: float = 0.3

@export_range(20.0, 80.0) var river_cliff_protection_slope: float = 42.0

@export_range(0.2, 1.0) var river_cliff_depth_scale: float = 0.58

@export var river_min_solid_shell: float = 1.45

## River bed color (vertex colored)
@export var river_bed_color: Color = Color(0.25, 0.22, 0.18)

@export_group("Terrain Material")
## Triplanar blend sharpness for the terrain shader (higher = crisper projection transitions)
@export var terrain_triplanar_sharpness: float = 3.5

## Strength of shader-driven twig/debris breakup
@export_range(0.0, 1.0) var terrain_twig_strength: float = 0.08

## Strength of shader-driven pebble/stone breakup
@export_range(0.0, 1.0) var terrain_pebble_strength: float = 0.10

@export_group("Erosion")
## Number of hydraulic erosion droplet iterations per chunk
@export var erosion_iterations: int = 200

## Erosion droplet inertia (0 = instant direction change, 1 = never turns)
@export_range(0.0, 1.0) var erosion_inertia: float = 0.3

## How much sediment a droplet can carry per unit speed
@export var erosion_capacity: float = 8.0

## Fraction of sediment deposited when over capacity
@export_range(0.0, 1.0) var erosion_deposition: float = 0.02

## Fraction of terrain eroded per step
@export_range(0.0, 1.0) var erosion_erosion_rate: float = 0.05

## Droplet evaporation rate per step
@export_range(0.0, 1.0) var erosion_evaporation: float = 0.02

## Maximum droplet lifetime in steps
@export var erosion_max_lifetime: int = 50

@export_group("Thermal Erosion")
## Enable thermal erosion pass (smooths steep slopes)
@export var thermal_erosion_enabled: bool = true

## Maximum stable slope angle in degrees
@export var thermal_max_slope: float = 40.0

## Number of thermal erosion passes
@export var thermal_iterations: int = 3

## Normalized elevation (0 = sea level, 1 = height_scale) above which thermal
## erosion fades out. Erosion applied at full strength everywhere planes off
## exactly the ridgelines and cliffs that give a landscape a skyline.
@export_range(0.0, 1.0) var thermal_high_ground_start: float = 0.45

## Normalized elevation where thermal erosion stops entirely.
@export_range(0.0, 1.0) var thermal_high_ground_end: float = 0.72

