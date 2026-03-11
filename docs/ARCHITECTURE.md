# Architecture

Godot ECS Starter is an ECS-style project structure built on top of Godot's native scene tree, not a separate ECS runtime.

## What ECS means here

### Entity
- Any `Node` or `Node3D` instance in the scene tree
- Examples:
  - a spawned flora instance
  - a fauna instance
  - a terrain chunk mesh

### Component
- A child node or script-backed node that carries focused configuration or behavior
- Examples:
  - `TerrainConfig`
  - `WaterConfig`
  - `BiomeData`
  - `FloraEntry`
  - `FaunaTraits`

### System
- A scene whose root extends `BaseSystem`
- It is placed under the world root and processed automatically

## Runtime structure

```text
World
├── ChunkManager
├── GeoSystem
├── TerrainSystem
├── RiverSystem
├── WaterSystem
├── NavigationSystem
├── BiomeSystem
├── WeatherSystem
├── CloudSystem
├── FloraSystem
├── FaunaSystem
├── FlyCamera
└── DebugHUD
```

## Core building blocks

### `World`
- Discovers all systems under the world scene
- Sorts them by `priority`
- Calls their lifecycle methods and per-frame processing

### `BaseSystem`
Every system inherits from `BaseSystem` and typically uses these hooks:

- **`_initialize()`**
  - set `system_name`
  - set `priority`
  - find config children

- **`_register_signals()`**
  - connect to `SystemBus`
  - subscribe to upstream events

- **`system_process(delta)`**
  - per-frame work
  - may be empty for event-driven systems

- **`_shutdown()`**
  - cleanup chunk data, spawned nodes, cached state

### `SystemBus`
- Event-driven communication channel
- Systems emit and connect to signals here
- Keeps systems loosely coupled

Examples:
- `terrain_chunk_ready`
- `biome_chunk_ready`
- `river_chunk_ready`
- `wind_changed`
- `chunk_unload_requested`

### `SharedWorld`
- Shared mutable runtime state
- Used for data that many systems read from repeatedly

Examples:
- sea level
- camera chunk position
- cached river data
- aggregate ecosystem counts

### `GameConfig`
- Project-wide settings and debug flags
- Things like chunk size, chunk loading radius, and debug logging live here

## Communication model

There are two approved communication channels.

### 1. Event communication through `SystemBus`
Use this when something happened.

Examples:
- terrain finished generating a chunk
- a weather state changed
- fauna ate flora
- a chunk should unload

### 2. Shared state through `SharedWorld`
Use this when data is continuously read by many systems.

Examples:
- sea level
- river cell caches
- total flora count
- total fauna count

## What not to do

- Do not wire systems together with hard references unless there is no cleaner option
- Do not make one system own another system's data pipeline
- Do not duplicate shared utility logic if the same concept already exists elsewhere

## Priority and data flow

Lower priority systems run first.

Typical flow:

```text
ChunkManager
  -> GeoSystem
  -> TerrainSystem
    -> RiverSystem
    -> WaterSystem
    -> NavigationSystem
    -> BiomeSystem
      -> FloraSystem
      -> FaunaSystem
```

That means downstream systems should usually consume data that upstream systems already produced.

## Chunk lifecycle

A chunk usually goes through this lifecycle:

1. `ChunkManager` decides a chunk is needed
2. `GeoSystem` provides macro climate and hydrology field sampling for the requested world region
3. `TerrainSystem` generates the heightmap, density field, caves, and river carve
4. `TerrainSystem` extracts the terrain mesh and derived carved surface heightmap
5. `terrain_chunk_ready` is emitted
6. Dependent systems build their chunk-local data from the authoritative terrain output
7. `chunk_unload_requested` is emitted later when the chunk should be removed
8. Each system cleans up its own state for that chunk

## Content model

The starter uses a single-scene content pattern.

### One content type = one scene
A content scene contains:
- the root entry script
- exported inspector configuration
- its visual children inline

Examples:
- `systems/flora/content/tree.tscn`
- `systems/fauna/content/deer.tscn`
- `systems/biome/content/forest.tscn`

This keeps content modular, readable, and drag-and-drop friendly.

## Adding a system safely

A new system should:
- extend `BaseSystem`
- own one clear responsibility
- expose tunables through a config child
- connect to `SystemBus` instead of reaching into sibling systems directly
- clean up chunk-local state when unloading

See **[Adding Systems and Content](ADDING_TO_GODOT_ECS_STARTER.md)** for the implementation workflow.

## River and water example

The river/water stack shows how the architecture is meant to work:

- `GeoSystem`
  - owns world-scale temperature, precipitation, drainage, rain-shadow, and basin guidance fields
  - exposes inspector-tunable macro field sampling to upstream world generation and downstream climate consumers

- `TerrainSystem`
  - samples geo-owned hydrology fields for river source suitability
  - traces rivers
  - accumulates river cells and local render paths
  - carves rivers as a terrain-owned channel/valley field inside the density volume
  - derives the carved surface heightmap that downstream systems read
  - applies local adaptive terrain refinement away from chunk borders for rivers, cliffs, and shores
  - stores river data in `SharedWorld`

- `RiverSystem`
  - reads terrain-owned river data
  - builds river surfaces from carved channel occupancy
  - samples carved terrain heights to place water inside the channel
  - shades rivers with chunk-local depth textures so river water stays in the same visual family as ocean water

- `WaterSystem`
  - renders sea-level water
  - handles ocean-style shading and underwater effects
  - cooperates with river surface detection

- `CloudSystem`
  - generates marching-cubes cloud blobs
  - renders solid voxel-colored cloud meshes
  - casts cloud shadows into the world

That pattern is the intended one:
- macro world fields are owned once and reused downstream
- generation system owns the data
- rendering system consumes the data
- communication stays reactive and explicit

## Current runtime notes

- `ChunkManager` now defaults to a `3x3` startup field around the player through `GameConfig.load_radius = 1`
- terrain seam safety is currently preserved by preventing adaptive refinement on chunk-border cells
- river terrain alignment is treated as a terrain problem first, not a visual ribbon problem
