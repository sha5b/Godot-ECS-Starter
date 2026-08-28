class_name GameConfigClass
extends Node

## Global configuration for the procedural world.
## Seed, dimensions, chunk settings, and debug flags.
##
## Autoloaded as a SCENE (autoloads/game_config.tscn), not as a bare script.
## Godot cannot show the inspector for a script autoload, so every @export
## below would be invisible and unsavable. Open game_config.tscn, select the
## root, and tune the whole world from the inspector — the values persist in
## that scene file.

## World seed — same seed = same world every time
@export var world_seed: int = 42

@export var randomize_seed_on_play: bool = true

## World dimensions in chunks (e.g. 64 = 64x64 chunk grid)
@export var world_size_chunks: int = 64

## Size of each chunk in world units
@export var chunk_size: float = 32.0

## How many chunks around the camera to keep loaded (radius).
##
## Measured on the target machine (Intel integrated GPU), fully streamed:
##   r=4   81 chunks  461 MB  14 fps
##   r=6  169 chunks  534 MB  23 fps
##   r=8  289 chunks  ~1.0 GB  9 fps
##   r=10 441 chunks  ~1.2 GB  1-2 fps, then stalls in swap
## Terrain memory and triangle count scale with the chunk COUNT, so this
## value dominates everything else in the frame budget. 6 gives a 416 m
## field, which is well past what is legible at normal camera distances —
## the far-ocean ring and the distance haze cover the frontier.
@export var load_radius: int = 6

## Buffer beyond load_radius before unloading (prevents thrashing)
@export var unload_buffer: int = 2

## Global simulation speed. Everything driven by delta scales with this —
## the day/night cycle, weather, critter movement, chemistry, gaits — so it
## is one dial for "how fast does the world live". 0.5 = half speed.
## The camera deliberately opts out (see rts_camera) so panning and zooming
## keep their normal feel no matter how slow the world is running.
@export_range(0.05, 4.0, 0.05) var game_speed: float = 0.5


## Debug flags
@export var debug_draw_chunk_borders: bool = false
@export var debug_draw_caves: bool = false
@export var debug_log_signals: bool = false
@export var debug_show_hud: bool = true

## Performance tier: 0 = nodes, 1 = servers, 2 = multimesh, 3 = shader
@export_range(0, 3) var performance_tier: int = 0


func _ready() -> void:
	Engine.time_scale = game_speed
	if randomize_seed_on_play:
		world_seed = int(Time.get_unix_time_from_system()) ^ int(Time.get_ticks_usec() & 0x7fffffff)
	# Always, not behind the debug flag. The seed is the only handle on which
	# world you are looking at: without it printed there is no way to tell a
	# fresh world from the same one again, and no way to go back to one you
	# liked. Set randomize_seed_on_play off and paste it in to reproduce.
	print("[GameConfig] Seed: %d | Chunks: %d | ChunkSize: %.1f"
		% [world_seed, world_size_chunks, chunk_size])


## Deterministic hash for a chunk coordinate — always returns same value for same input
func chunk_hash(chunk_x: int, chunk_z: int) -> int:
	return hash(Vector2i(chunk_x, chunk_z)) ^ world_seed
