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

- **BotW-style ECS runtime**
  - data-oriented actors with a chemistry engine (elements × materials), utility AI, and tiered processing
  - see **[ECS Runtime](docs/ECS_RUNTIME.md)**

## Documentation

- **[Docs index](docs/README.md)**
- **[Architecture](docs/ARCHITECTURE.md)**
- **[Adding to Godot ECS Starter](docs/ADDING_TO_GODOT_ECS_STARTER.md)**
- **[Design Doctrine](docs/DESIGN_DOCTRINE.md)**

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
│   ├── ecs/            BotW-style ECS runtime (chemistry, utility AI, tiers)
│   ├── terrain/
│   ├── river/
│   ├── water/
│   ├── biome/
│   ├── weather/
│   ├── cloud/
│   ├── flora/
│   ├── fauna/
│   └── navigation/
├── tests/              headless unit tests + visual integration test
└── project.godot
```

## Testing

```bash
# Unit tests (45 tests, exits non-zero on failure)
godot --headless --path . --script tests/run_tests.gd

# Visual integration test (fire spread, panic, rain, lightning, ice)
# Also runnable in the editor: open tests/visual/ecs_visual_test.tscn
godot --headless --path . res://tests/visual/ecs_visual_test.tscn
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

| Input | Action |
|---|---|
| **WASD / arrows** | Pan camera |
| **Mouse wheel** | Smooth zoom |
| **Hold right mouse + move** | Rotate / tilt |
| **Q / E** | Rotate (keyboard) |
| **Middle-drag** | Fast pan |
| **Shift** | Double pan speed |

The camera eases toward its target pose, keeps its focus on the ground, and
shortens its boom when terrain would block the view.
