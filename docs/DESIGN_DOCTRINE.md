# Design Doctrine

This document defines the engineering philosophy and hard architectural rules for Godot ECS Starter.

## Core philosophy

**Godot ECS Starter extends Godot instead of replacing it.**

The project is intentionally built from:
- scenes
- nodes
- autoloads
- signals
- inspector configuration

It does not depend on a custom ECS runtime, C++ module, or external addon to express the architecture.

## The three pillars

### Drop-in
- Systems are scenes
- Content is scene-based
- New functionality should be modular and easy to place in the world tree

### Reactive
- Systems communicate through `SystemBus`
- Shared runtime state lives in `SharedWorld`
- Loose coupling is preferred over direct references

### Inspector-first
- Important tuning values should be `@export`
- Designers should be able to tune behavior without rewriting code

## Architecture rules

### 1. Systems are scenes
A system is a scene whose root extends `BaseSystem`.

It should:
- have a clear responsibility
- own its local state
- connect to upstream signals
- clean up after itself

### 2. Config is a child node
Each system should have a focused config child.

That config should:
- extend `Node`
- use `@export`
- describe tunable system-level behavior

### 3. Content uses the single-scene pattern
One content type equals one `.tscn` file.

That file contains:
- root entry script
- exported configuration
- visual children inline

This applies across flora, fauna, biomes, and future content-driven systems.

### 4. Shared ownership must be explicit
Each major data pipeline should have one authoritative owner.

Examples:
- macro geography, climate, and hydrology fields belong to `GeoSystem`
- terrain generation belongs to `TerrainSystem`
- river tracing/carving data belongs to `TerrainSystem`
- river visual rendering belongs to `RiverSystem`
- sea-level water visuals belong to `WaterSystem`
- cloud mesh generation belongs to `CloudSystem`

Renderers should consume authoritative data instead of inventing parallel truth.

For terrain-driven water features this means:
- the geo system owns world-scale temperature, precipitation, drainage, and basin guidance fields
- the terrain system owns the carved river corridor and derived surface heights
- the river renderer consumes that carved terrain shape instead of inventing an unrelated ribbon path
- adaptive refinement may increase local detail, but chunk-border topology must remain seam-safe

### 5. Prefer reuse over duplication
Before adding a new helper, signal, or pattern:
- search for an existing equivalent
- generalize if appropriate
- only add a new abstraction if the concept is truly missing

### 6. Functions should stay readable
Prefer:
- explicit names
- short focused functions
- decomposition over cleverness

If a function is hard to explain in one sentence, it likely needs to be split.

## Communication rules

### Use `SystemBus` for events
Use signals when:
- something happened
- another system may need to react
- the sender should not know who the receivers are

### Use `SharedWorld` for shared runtime state
Use shared state when:
- multiple systems read the same evolving world data
- the data belongs to the persistent runtime model

### Avoid direct system dependencies
Do not build hidden coupling by passing systems around unless there is no simpler alternative.

## Data flow philosophy

The preferred flow is:

```text
authoritative generation -> shared data/state -> rendering/consumption
```

Examples:
- geo samples macro climate fields, then terrain, biome, and weather systems consume them
- terrain generates a chunk, then downstream systems consume it
- biome classification produces biome data, then spawn systems consume it
- terrain river cells define the carved channel, then river rendering consumes those cells
- cloud meshes generate solid voxel-colored geometry first, then the cloud shader applies downstream tinting and lighting

## Error handling rules

Systems should degrade gracefully.

Preferred behavior:
- missing config -> create fallback defaults and warn
- missing optional content -> keep running
- missing neighbor data -> skip safely
- missing listeners -> signal remains harmless

Crashes should be the exception, not the baseline.

## Performance philosophy

### Correctness first
Start with the clearest implementation that is easy to reason about.

### Optimize after proof
When profiling demands it, optimize in layers:
- cached queries
- better chunk-local data structures
- server-level rendering
- `MultiMesh`
- threaded generation
- shader-driven detail

## Extension philosophy

When adding a feature:
- identify the owner of the data
- define the event flow
- decide what belongs in shared state
- keep the rendering side downstream from the data side
- prefer scene-based composition over hidden setup code

## Golden rule

**If a new system cannot be described in one sentence, it is probably doing too much.**
