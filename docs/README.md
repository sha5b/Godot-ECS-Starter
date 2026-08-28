# Godot ECS Starter Docs

Godot ECS Starter is a Godot-native, inspector-first ECS-style starter kit built from scenes, nodes, signals, and shared state instead of a custom ECS framework.

## Start Here

- **[Architecture](ARCHITECTURE.md)**
  - How the world is structured
  - How systems run
  - How systems communicate

- **[Adding Systems and Content](ADDING_TO_GODOT_ECS_STARTER.md)**
  - How to add a new system
  - How to add new content scenes
  - What extension rules to follow

- **[Design Doctrine](DESIGN_DOCTRINE.md)**
  - Core engineering philosophy
  - Architectural rules
  - Content authoring rules

- **[ECS Runtime](ECS_RUNTIME.md)**
  - BotW-style actor layer: entities, chemistry engine, utility AI
  - Tiered processing and how to use the runtime

- **[Architecture Review](ARCHITECTURE_REVIEW.md)**
  - What was measured, what was fixed, and what is still open
  - Read this before extending the actor, terrain, water, or biome layers

## Documentation Map

### Core concepts
- **Entity**
  - Any `Node` or `Node3D` instance participating in the world

- **Component**
  - A child node with exported configuration or specialized behavior

- **System**
  - A scene whose root extends `BaseSystem`

- **Shared state**
  - Stored in autoloads like `SharedWorld` and `GameConfig`

- **Reactive communication**
  - Event-driven flow through `SystemBus`

### Key runtime pieces
- **`systems/base/world.gd`**
  - Discovers and processes systems by priority

- **`systems/base/base_system.gd`**
  - Base lifecycle for all systems

- **`autoloads/system_bus.gd`**
  - Cross-system event bus

- **`autoloads/shared_world.gd`**
  - Shared runtime world state

- **`autoloads/game_config.gd`**
  - Global configuration and debug flags

- **`systems/ecs/`**
  - Data-oriented ECS runtime: entities, chemistry, utility AI, tiers
  - Hosted by `EcsSystem`, tested in `tests/`

## Quick mental model

```text
ChunkManager loads chunks
  -> GeoSystem provides macro climate and hydrology fields
  -> TerrainSystem generates terrain, caves, and terrain-owned river carve data
    -> RiverSystem renders river water from carved terrain-owned data
    -> WaterSystem renders sea-level water and underwater effects
    -> NavigationSystem bakes navigation
    -> BiomeSystem classifies terrain
  -> WeatherSystem drives atmosphere and time-of-day
    -> CloudSystem renders solid voxel-colored cloud meshes and shadows
      -> FloraSystem spawns flora
      -> FaunaSystem spawns fauna
```

## Principles

- **Godot-native first**
  - Prefer scenes, nodes, autoloads, signals, and inspector configuration

- **Drop-in composition**
  - New systems and content should be addable without editing unrelated code

- **Inspector-first workflow**
  - Tunables should live in `@export` properties whenever practical

- **Reactive communication**
  - Systems should communicate through signals and shared state instead of tight coupling
