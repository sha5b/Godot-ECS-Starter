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

### Flora example
```text
systems/flora/content/tree.tscn
├── Tree                 # root with FloraEntry script
├── Trunk                # MeshInstance3D
└── Canopy               # MeshInstance3D
```

### Fauna example
```text
systems/fauna/content/deer.tscn
├── Deer                 # root with FaunaEntry script
├── Body                 # MeshInstance3D
└── Optional child nodes # traits, helpers, etc.
```

### Biome example
```text
systems/biome/content/forest.tscn
└── Forest               # root with BiomeData script
```

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
