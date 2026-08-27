# ECS Runtime — the BotW-style actor layer

`systems/ecs/` contains a data-oriented entity runtime modeled on the three
ideas that make Breath of the Wild's engine special:

1. **Chemistry engine** — elements × materials in an inspector-editable
   rule matrix, with emergent propagation (fire spreads downwind, lightning
   chains through wet conductors, rain puts fires out, ice freezes soaked
   bodies)
2. **Utility-based AI** — agents score actions through response-curve
   considerations and commit to the winner, instead of behavior trees
3. **Tiered processing** — near actors simulate every frame, mid-range every
   4th, far every 12th, out-of-range actors go dormant

The runtime is pure data (`RefCounted`, no nodes), so it runs headless and
is covered by unit tests. Scene-tree visuals are a separate view layer.

## Runtime structure

```text
EcsSystem (BaseSystem bridge, drop-in under World or standalone)
└── EcsWorld                     entities, stores, queries, events, commands
    └── EcsScheduler             ordered phases + per-system profiling
        ├── EARLY  TierSystem        distance-based tier assignment
        ├── SIM    MovementSystem    integrates velocity
        ├── SIM    UtilityAISystem   sense -> decide -> act
        ├── SIM    ChemistrySystem   elements × materials simulation
        ├── SIM    VitalitySystem    deaths + expired lifetimes
        └── VIEW   ViewSyncSystem    mirrors data onto EntityView nodes
```

Command buffer flushes happen at phase boundaries so each phase sees a
consistent structure — the same sync-point discipline BotW uses between
actor update passes.

## Core concepts

### Entities
Generational int handles (`index | generation << 32`). A despawned handle
fails `is_alive()` safely, even after the index is recycled.

### Components
Plain `RefCounted` data classes in `systems/ecs/components/`, stored in
sparse-set stores keyed by `COMPONENT_ID`:

- `CTransform` / `CVelocity` — spatial state
- `CHealth` — hit points, death flag
- `CBody` — surface material (`GRASS`, `WOOD`, `METAL`, `STONE`, `FLESH`), fuel, mass
- `CElemental` — element intensities, wetness, burning, frozen, constants
- `CAgent` — drives, committed action, cooldowns, sensor blackboard
- `CFood` — marks an entity as edible
- `CLifetime` — auto-despawn timer

### Queries
`world.query([&"CTransform", &"CElemental"])` returns a live cache that
updates on every structural change. Caches are partitioned by processing
tier, so systems iterate exactly the entities they owe work for this frame:

```gdscript
for entity in world.frame_entities(cache, frame):
    var dt := world.entity_delta(entity, delta)  # scaled by tier cadence
    ...
```

### Commands
Structural changes during iteration go through `world.commands`
(spawn_with / despawn / add / remove) and apply at phase flushes.

### Events
`world.publish(&"chemistry.ignited", {...})` + `world.drain(...)`.
`EcsSystem` forwards everything to `SystemBus.ecs_event(channel, payload)`
and to registered event watchers (the visual FX use those).

## The chemistry engine

`ChemistryRules` (a `Resource`) holds the full rulebook: one
`ElementReaction` per element × material pair (ignite chance, burn damage,
conductivity, wet gain, douse, freeze, virulence) plus global tuning
(spread radius, wind boost, arc range/falloff, rain wet rate...).
Replace the resource in the inspector to change the physics of a world.

Per processed body each tick:

1. rain wets, evaporation dries (faster while burning)
2. active elements act, then decay (constant sources re-apply)
3. FIRE rolls ignition (blocked by wetness gate), burns fuel, damages
   health, and spreads to flammable neighbors — biased downwind
4. ELECTRICITY arcs through conductive bodies; the carrier discharges
   into the arc so the wave dies out after a few hops
5. ICE freezes wet bodies; frozen bodies eventually thaw
6. WATER/ICE constant sources (puddles, ice shards) radiate their element
   to nearby bodies

Lightning is one call: `ecs.strike(position, power)`.

## Utility AI

Brains are `UtilityBrain` resources holding `UtilityAction`s, each scored
from `Consideration`s (an input + a response curve: linear, polynomial,
inverse, logistic, step). Scores combine with Dave Mark's compensated
product; a new winner must beat the committed action by `switch_margin`
(hysteresis), and interrupt actions (`panic`) take over immediately.

`UtilityBrain.critter_brain()` builds the stock foraging brain:
`panic / flee / seek_food / rest / wander`. Ignite grass near critters and
panic wins every score — the emergent "grass fire chases animals" moment.

## Tiered processing (BotW A/B/C profiles)

| Tier | Cadence | Typical range |
|---|---|---|
| 0 | every frame | near focus |
| 1 | every 4th frame | mid |
| 2 | every 12th frame | far |
| 3 | dormant | out of range |

Per-entity staggering (`(frame + index) % cadence`) spreads coarse tiers
across frames. Coarse tiers receive scaled delta so behavior stays
frame-rate independent. Distances are `@export`s on the `EcsConfig` child.

## Using it

The runtime is live in the main world scene (`EcsSystem` under `World`) and
**populates itself from the generated world**: every loaded chunk seeds an
invisible layer of chemistry grass (fire spreads through the *visible*
foliage — the renderer recolors instances near ignite/char/extinguish/freeze
events), a few foraging critters with utility AI, edible berry bushes for
the seek-food loop, and the occasional lit campfire as a permanent fire
source. Everything despawns with its chunk. Weather couples automatically: the WeatherSystem's rain soaks
bodies and douses fires, and wind biases fire spread. Press **L** to call
lightning down at the camera focus — strikes ignite dry grass (BotW rules).
Densities are inspector knobs on the `EcsConfig` child
(`chemistry_grass_per_chunk`, `critters_per_chunk`, `populate_world`).

Any script can reach the runtime:

```gdscript
var ecs: EcsSystem = get_tree().get_first_node_in_group(&"ecs_systems")  # or a direct node ref
var entity := ecs.world.spawn()
ecs.world.add_component(entity, CTransform.new())
# ...
```

For standalone scenes, drop `systems/ecs/ecs_system.tscn` anywhere — it
ticks itself when not under a `World` root.

## Testing

- Unit tests: `godot --headless --path . --script tests/run_tests.gd`
  (45 tests over world, queries, commands, chemistry, AI, scheduler)
- Visual integration test: open
  `res://tests/visual/ecs_visual_test.tscn` and press play, or run it
  headless — it drives a scripted scenario (fire spread → panic → rain →
  lightning → ice) and exits non-zero on failure:

  ```
  godot --headless --path . res://tests/visual/ecs_visual_test.tscn
  ```

The scene uses an RTS-style god camera — there is no player avatar.
Pan with **WASD**/arrows, zoom with the mouse wheel, rotate with **Q/E**,
fast-pan with middle-mouse drag. The camera focus feeds
`SharedWorld.camera_world_pos`, so ECS tiers and AI threats follow it.
Other keys: **R** rain, **L** lightning, **F1** restart.

### Performance model (and how it was profiled)

The visual test prints per-system CPU times when it finishes, and
`ChemistrySystem.debug_profile` breaks the chemistry tick into sections.
The rules that keep the demo at frame rate:

- **Electric arcs have a refractory window** — freshly shocked bodies
  cannot re-arc for a moment, so a strike becomes an expanding ring that
  dies out. Without it, arcs re-trigger each other exponentially through
  wet ground (a single strike was measured at 42ms of CPU per tick).
- **Fire spread is time-sliced** — sources roll spread every Nth frame
  with scaled delta (same expected rate, fraction of the cost).
- **Views are event-driven** — grass recolors only on chemistry events,
  grouped into 8m chunks; FX nodes come from pre-allocated pools instead
  of spawning a node per event.
- **Coarse work is throttled** — the spatial grid rebuilds every few
  frames, AI sensor lists refresh on timers, constant-source auras use a
  cached source list.
