# Adding to Godot ECS Starter

This guide explains how to extend Godot ECS Starter without fighting the existing architecture.

## Add a new system

### 1. Create a system folder
Use a clear, colocated structure.

```text
systems/my_system/
├── my_system.gd
├── my_system.tscn
├── my_system_config.gd
└── content/
```

If the system has no drop-in content types, the `content/` folder can be omitted.

### 2. Create the config node
Create a config script that extends `Node` and expose tunables with `@export`.

Example responsibilities:
- density
- update interval
- radius
- thresholds

### 3. Create the system script
The root script should extend `BaseSystem`.

Typical pattern:
- set `system_name`
- set `priority`
- find the config child
- connect required signals
- process events or frame updates

### 4. Create the system scene
The system scene should contain:
- root node with the system script
- one config child
- optional content scenes as children

### 5. Drop it under `World`
Once the system scene is placed under the world scene, it becomes part of the runtime pipeline.

## Add a new signal

Only add a signal to `SystemBus` when it represents a meaningful cross-system event.

Good examples:
- a chunk finished generating
- a biome map became available
- an ecosystem interaction happened

Bad examples:
- internal implementation details that only one system cares about

## Add shared state

Only add data to `SharedWorld` when:
- multiple systems need to read it continuously
- the data is part of the shared runtime model

Do not use `SharedWorld` as a dump for random temporary values.

## Add new content

The content pattern is intentionally simple.

### Rule
One content type equals one `.tscn` file.

That scene contains:
- the entry script on the root
- exported inspector settings
- mesh children inline

Content roots are `Node3D`, so a content scene is a real 3D prefab: you can
move, rotate and scale it in the editor and see gizmos on it.

### Flora example
```text
systems/flora/content/tree.tscn
├── Tree                 # root with FloraEntry script (Node3D)
├── Trunk                # MeshInstance3D
└── Canopy               # MeshInstance3D
```

Set **Rendering > Drawn By Foliage Shader** on grass-like entries that the
`FoliageSystem` ground-cover shader already draws, so the two renderers do not
both plant the same cover. Nothing keys off `entry_name` — you can name a new
plant anything.

### Fauna example
```text
systems/fauna/content/deer.tscn
├── Deer                 # root with FaunaEntry script (Node3D)
├── Body                 # MeshInstance3D
└── Optional child nodes # traits, helpers, etc.
```

A fauna content scene defines a **species**. The ECS registers it as a founding
species at startup, spawns members of it biome-gated by `allowed_biomes` /
`excluded_biomes` up to `max_per_chunk`, and then breeds and evolves them.
Four export groups decide what kind of animal it is:

- **Genetics** — `genome_archetype` picks the body plan (grazer, runner,
  pouncer, serpent, glider) that every member of the species is built on.
  `genome_variance` is how different individuals are at birth;
  `speciation_distance` is how far a lineage may drift before it splits off
  as a new species. `use_procedural_body` chooses between the genome-driven
  body (evolution is visible) and this scene's own meshes.
- **Behavior** — `diet` and `prey_names` decide whether this animal hunts.
  A carnivore with a prey list gets a hunting brain; everything else forages.
  Prey names refer to other FaunaEntry names, and keep working after either
  side speciates.
- **Behavior > flocking** — `flocking` plus the `flock_*` weights turn the
  species into a herd, flock, shoal or pack. Members steer with same-species
  neighbours and break formation when they flee.
- **Lifecycle / Breeding** — ages, hunger, and how often it reproduces.

You do not register the scene anywhere: drop it under `FaunaSystem` and it is
part of the world.

### Biome example
```text
systems/biome/content/forest.tscn
└── Forest               # root with BiomeData script
```

A new biome needs nothing but this scene. Two export groups are worth setting:

- **Ground Cover** — lushness, dryness, scale, density bonus and sprite
  weights for the `FoliageSystem`. Leave them alone and the biome grows
  neutral ground cover; no renderer code knows any biome by name.
- **Surface Biome** — turn it OFF for interiors like caves, or the biome will
  compete for open ground and win it.

Climate envelopes are weighted by specificity: a narrow temperature/moisture
band beats a wide one inside its range. Give a biome wide tolerances to make
it a fallback, narrow ones to make it a specialist.

## Add a new flora or fauna type

### Workflow
- create one content scene in the system's `content/` folder
- attach the correct entry script to the root
- configure exported values in the inspector
- add mesh children inline
- wire the scene as a child of the system scene

No separate registration file should be needed.

## Communication rules

When extending the starter, follow this communication order.

### Use `SystemBus` when
- work should happen in response to an event
- a downstream system needs to react once

### Use `SharedWorld` when
- data is read repeatedly by multiple systems
- the data belongs to the world model

### Avoid direct system calls when
- the same result can be achieved through signals or shared state

## Naming rules

- **System script**
  - `snake_case_system.gd`

- **System scene**
  - `snake_case_system.tscn`

- **Config script**
  - `snake_case_config.gd`

- **Entry script**
  - `snake_case_entry.gd`

- **Content scene**
  - `snake_case.tscn`

- **Signal**
  - `noun_verb_past`

## Design checklist before merging a new feature

- **Single responsibility**
  - does the new system do one clear job?

- **Inspector-first**
  - are key tunables exported?

- **Reuse**
  - did you search for an existing helper or pattern first?

- **Communication fit**
  - is the feature using `SystemBus` and `SharedWorld` appropriately?

- **Chunk cleanup**
  - does it remove per-chunk data on unload?

- **Scene workflow**
  - can a designer add the feature without code edits where appropriate?

## Recommended extension order

When building a bigger feature:
- define data ownership first
- decide which events should exist
- add shared state only if needed
- implement generation before rendering
- keep rendering as a consumer of authoritative data

That pattern is especially important for terrain, rivers, caves, biomes, flora, and fauna.
