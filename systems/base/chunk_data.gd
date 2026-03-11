class_name ChunkData
extends Resource

## Per-chunk data container.
## Passed between systems via SystemBus signals.

## Chunk grid coordinate
@export var coord: Vector2i = Vector2i.ZERO

## Surface heightmap — flat array, row-major, resolution = chunk_resolution^2
## Derived from the density field (topmost solid→air transition per column).
## Used by Flora, Fauna, Navigation, and other systems for surface queries.
var heightmap: PackedFloat32Array = PackedFloat32Array()

## 3D density grid — flat array [y * res_xz * res_xz + z * res_xz + x]
## Positive = solid, Negative = air. Surface is at density == 0.
var density_grid: PackedFloat32Array = PackedFloat32Array()

## Vertical resolution of the density grid
var density_res_y: int = 0

## Biome map — flat array, one byte per cell (biome index)
var biome_map: PackedByteArray = PackedByteArray()

## Flora positions — packed array of Vector3 world positions
var flora_positions: PackedVector3Array = PackedVector3Array()

## Flora type indices — one int per flora instance, indexes into FloraConfig.flora_scenes
var flora_types: PackedInt32Array = PackedInt32Array()

## Whether this chunk's terrain has been generated
var terrain_ready: bool = false

## Whether this chunk's biomes have been mapped
var biomes_ready: bool = false

## Whether this chunk's flora has been placed
var flora_ready: bool = false


## Resolution of the heightmap grid (heightmap has resolution * resolution entries)
func get_resolution() -> int:
	var side := int(sqrt(heightmap.size()))
	return side if side * side == heightmap.size() else 0


## Sample heightmap at local grid coordinate (clamped)
func sample_height(local_x: int, local_z: int) -> float:
	var res := get_resolution()
	if res == 0:
		return 0.0
	local_x = clampi(local_x, 0, res - 1)
	local_z = clampi(local_z, 0, res - 1)
	return heightmap[local_z * res + local_x]


## Get biome index at local grid coordinate (clamped)
func sample_biome(local_x: int, local_z: int) -> int:
	var res := get_resolution()
	if res == 0:
		return 0
	local_x = clampi(local_x, 0, res - 1)
	local_z = clampi(local_z, 0, res - 1)
	return biome_map[local_z * res + local_x]


## Sample density at 3D grid coordinate (clamped)
func sample_density(gx: int, gy: int, gz: int) -> float:
	var res_xz := get_resolution()
	if res_xz == 0 or density_res_y == 0:
		return 1.0
	gx = clampi(gx, 0, res_xz - 1)
	gy = clampi(gy, 0, density_res_y - 1)
	gz = clampi(gz, 0, res_xz - 1)
	return density_grid[gy * res_xz * res_xz + gz * res_xz + gx]
