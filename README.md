# Godot ECS Starter

Godot ECS Starter is a Godot-native, inspector-first ECS-style starter kit built from scenes, nodes, signals, and shared state instead of a custom ECS runtime.

## What it is

- **Godot-native**
  - systems are scenes
  - components are nodes with exported configuration
  - global coordination lives in autoloads

- **Reactive**
  - systems communicate through `SystemBus`
  - shared runtime data lives in `SharedWorld`

- **Drop-in friendly**
  - new systems can be added under `World`
  - new flora, fauna, and biome content can be added as single `.tscn` scenes

## Documentation

- **[Docs index](docs/README.md)**
- **[Architecture](docs/ARCHITECTURE.md)**
- **[Adding to Godot ECS Starter](docs/ADDING_TO_GODOT_ECS_STARTER.md)**
- **[Design Doctrine](docs/DESIGN_DOCTRINE.md)**
- **[Implementation Plan](docs/IMPLEMENTATION_PLAN.md)**

## How it works

At runtime, the world scene hosts a set of systems that process in priority order.

Typical flow:

```text
ChunkManager
  -> TerrainSystem
    -> RiverSystem
    -> WaterSystem
    -> NavigationSystem
    -> BiomeSystem
      -> FloraSystem
      -> FaunaSystem
```

Each system owns one responsibility.

Examples:
- `TerrainSystem`
  - generates terrain, caves, and river data

- `RiverSystem`
  - renders river water from terrain-owned river data

- `WaterSystem`
  - renders ocean/sea-level water and underwater effects

- `BiomeSystem`
  - classifies terrain into biomes

- `FloraSystem` / `FaunaSystem`
  - spawn and manage biome-aware content

## How systems communicate

There are two main channels.

### `SystemBus`
Use `SystemBus` for events.

Examples:
- `terrain_chunk_ready`
- `biome_chunk_ready`
- `river_chunk_ready`
- `chunk_unload_requested`

### `SharedWorld`
Use `SharedWorld` for continuously shared world state.

Examples:
- sea level
- river cell caches
- ecosystem counters

## How to add to it

### Add a new system
- create `systems/my_system/`
- add `my_system.gd`
- add `my_system_config.gd`
- create `my_system.tscn`
- place the scene under `World`

### Add new content
Use the single-scene content pattern:

- one content type = one `.tscn`
- root entry script + exported settings + mesh children inline

Examples:
- `systems/flora/content/tree.tscn`
- `systems/fauna/content/deer.tscn`
- `systems/biome/content/forest.tscn`

See **[Adding to Godot ECS Starter](docs/ADDING_TO_GODOT_ECS_STARTER.md)** for the detailed workflow.

## Repo layout

```text
res://
├── autoloads/
├── docs/
├── scenes/
├── systems/
│   ├── base/
│   ├── terrain/
│   ├── river/
│   ├── water/
│   ├── biome/
│   ├── weather/
│   ├── cloud/
│   ├── flora/
│   ├── fauna/
│   └── navigation/
└── project.godot
```

## Starter principles

- **clarity over cleverness**
- **data ownership should be explicit**
- **generation systems produce authoritative data**
- **rendering systems consume that data**
- **inspector-first workflows should stay easy**

## Current focus areas

- terrain-authoritative river rendering
- better river/ocean blending
- chunk-safe world generation
- extensible scene-based content systems

## Controls

| Key | Action |
|---|---|
| **WASD** | Move camera |
| **Mouse** | Look around |
| **Shift** | Fast move |
| **Space / Ctrl** | Up / Down |
| **Escape** | Toggle mouse capture |
