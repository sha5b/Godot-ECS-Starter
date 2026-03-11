# Implementation Plan

This roadmap tracks the current state and next major phases of Godot ECS Starter.

## Current state

### Core framework
- complete base lifecycle through `World`, `BaseSystem`, `ChunkManager`, `ChunkData`, and autoloads
- system discovery and priority-based execution are in place

### World generation
- macro geography, climate, and hydrology field sampling is active through `GeoSystem`
- voxel terrain generation is active
- river tracing, terrain-owned channel/valley carving, and river rendering are active
- adaptive terrain refinement is active for rivers, cliffs, and shores away from chunk borders
- cave generation and cave entrances are active
- ocean/shallow/deep water rendering is active

### Ecosystem
- biome classification is active
- flora and fauna content systems are active
- lifecycle, breeding, and ecosystem signaling foundations are active

### Atmosphere and presentation
- weather cycle is active
- cloud system is active with solid voxel-colored cloud meshes and cloud shadow casting
- underwater detection is active
- debug HUD and fly camera are active

### Runtime defaults
- chunk loading now defaults to a `3x3` field around the player via `GameConfig.load_radius = 1`

## Near-term priorities

### 1. River system stabilization
- tune macro precipitation, drainage, and basin guidance so river density varies more clearly by region
- improve river/ocean blending further
- improve outlet transitions
- keep reducing terrain clipping in steep terrain where the mesh still blocks river corridors
- finish river flow UV mapping so the water motion does not stretch
- finish smooth-shaded river surfacing instead of faceted top quads
- continue refining terrain-authoritative channel alignment and carved cross-sections

### 2. Documentation and starter polish
- present the repo clearly as Godot ECS Starter
- improve onboarding docs
- make extension workflows easier to follow

### 3. Visual polish
- richer ocean motion
- stronger shoreline interaction
- improved vegetation ground detail
- more atmospheric polish near water and coastlines

## Medium-term roadmap

### Structure system
- introduce placeable/generated structures
- flat-placement and footprint handling
- future settlement/ruin content pattern

### Player interaction
- player controller system
- swimming and water interaction
- terrain/world interaction
- harvesting/building loops

### Performance scaling
- threaded generation where valuable
- better chunk budgets
- future `MultiMesh`/server-driven optimization for high-instance content

## Long-term roadmap

### Advanced rendering
- richer terrain material blending
- more advanced water surfacing and shoreline behavior
- stronger post-processing and atmospheric depth

### Content pipeline
- better editor-side workflows
- world presets
- optional modding/runtime extensibility

## Architectural direction

The project continues to follow these rules:
- macro world fields are owned upstream and sampled by downstream systems
- generation systems own authoritative data
- rendering systems consume that data
- systems communicate through `SystemBus` and `SharedWorld`
- extension should stay scene-based and inspector-friendly

## Current focus note

The river stack is currently the most actively evolving subsystem because it sits at the intersection of:
- terrain generation
- carved channels
- adaptive terrain meshing
- water rendering
- ocean blending
- underwater interaction

That work should continue to favor terrain-owned data and downstream rendering instead of parallel visual-only approximations.
