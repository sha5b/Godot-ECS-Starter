# Procedural Critter Bodies — Analysis & Plan

Spore-style procedural bodies for every critter, built **inside the ECS
architecture**: a genome describes the body plan (spine, limbs, head, tail,
wings, colors) and its **rest angles** and **gait angles**; a builder turns
the genome into a rigged node hierarchy; a gait controller animates the rig
procedurally; and a **sim-phase breeding system** recombines and mutates
genomes through the command buffer, so bodies evolve under the existing
survival simulation.

Everything ships and is tested in the **Body Lab** first — a real
`EcsWorld` + `EcsScheduler` running the same production systems. The main
world keeps its current critters until the lab output passes visual QA;
deployment is then two `EcsConfig` flags.

---

## 1. What Spore actually does (and what we keep)

| Spore concept | What it means there | What we do here |
|---|---|---|
| Body plan as data | Creature is a list of parts with sizes/positions | `CritterGenome`: flat clamped gene set (counts + lengths + **angles** + colors) |
| Spine / vertebrae | Dragged spine blobs define torso shape | Chain of sphere-segment joints, per-joint radius + bend angles |
| Limb placement | Parts snap anywhere | Constrained slots: 0–2 leg pairs on spine segments, optional wing pair |
| Live procedural animation | Engine animates whatever rig exists (no baked clips) | `CritterGait`: FK leg cycles + spine wave + head/tail bob from gait genes |
| Angles define silhouette | Shoulder/knee/rest angles shape the creature | First-class genes: `knee_bend`, `stance_splay`, `snout_droop`, `ear_angle`, `tail_droop`, `spine_arch` |
| Evolution | Editor-driven, archetype fitness | **Automatic**: `BreedingSystem` crossovers + mutates genomes on reproduction; derived stats make body genes selectable |

Deliberately out of scope for phase 1: skeleton skinning
(`Skeleton3D` + skinned meshes), player-facing editors, texture-accurate
patterns. The rig is a `Node3D` joint hierarchy with stylized primitive
meshes — matching the project doctrine (stylized, fast, inspector-first)
and the existing wing-flap convention (`WingL`/`WingR` lookups in
`FaunaSystem`).

## 2. Why a Node3D joint chain instead of Skeleton3D

- The ECS doctrine says the scene tree is a **view** — the world owns no
  engine objects and stays headless-testable. A plain joint hierarchy with
  group-tagged nodes is pure view data; generating + skinning a
  `Skeleton3D` procedurally in GDScript is slow and untestable that way.
- `ViewSyncSystem` binds views by node; a node rig slots straight into the
  existing `bind()` path, and survives `Node.duplicate()` (the FaunaSystem
  spawn path) because groups and scripts duplicate with it.
- Dozens of critters × a dozen joints of FK math per frame is trivial CPU
  cost, and it fits the tiered-processing doctrine: far tiers can tick the
  gait at coarse cadence later.
- Upgrade path stays open: the genome is renderer-agnostic. A later phase
  can generate a `Skeleton3D` + skinned mesh from the *same* genes.

## 3. Component design (phase 1 — shipped in this change)

```
SIM LAYER (headless, engine-free)
  systems/critter/critter_genome.gd            CritterGenome (RefCounted)
  systems/ecs/components/c_genome.gd           CGenome component
  systems/ecs/systems/breeding_system.gd       BreedingSystem (SIM phase)

VIEW LAYER (scene tree, cosmetic only)
  systems/critter/critter_body_builder.gd      CritterBodyBuilder (static)
  systems/critter/critter_torso.gd             CritterTorso (swept-tube skinner)
  systems/critter/critter_gait.gd              CritterGait (Node)
  systems/critter/critter_view.gd              CritterView extends EntityView

TEST ENVIRONMENT
  scenes/body_lab.gd + body_lab.tscn           interactive lab on a real world
```

Data flows one direction, exactly like the rest of the runtime:
**genome → CGenome → (breeding) → commands → CGenome → CritterView →
body + gait**. Nothing in the view ever writes simulation state.

### 3.1 CritterGenome — the data layer

Three gene kinds, all clamped to hard ranges so mutation can never produce
a broken body:

- **Structural counts**: `body_segments 2–7`, `leg_pairs 0–2`,
  `tail_segments 0–6`, `eye_count 2–4`, `pattern none/stripes/spots`,
  `gait_pattern walk/trot/pace/bound`, `has_wings 0/1`.
- **Proportions**: segment length/girth/taper, head size, snout length,
  ear/horn size, leg length/girth, foot size, tail length, wing span,
  HSV palette + belly lightness + accent amount.
- **Angles** (the Spore soul of the system): rest pose — `spine_arch`
  (dorsal curve), `snout_droop`, `ear_angle`, `knee_bend` (rest bend of
  the legs), `stance_splay` (hips yawed outward), `tail_droop`, and gait —
  `stride_amp` (hip swing), `knee_lift`, `spine_wave` (lateral
  undulation), `head_bob`, `tail_wag`, `gait_cycle` (stride frequency),
  `wing_flap`.

API: `CritterGenome.randomized(rng)` (deterministic, coherent bodies),
`mutate(rng, rate)` (gaussian drift + ±1 count steps + rare flips),
`CritterGenome.crossover(a, b, rng)` (pick-or-blend per gene),
`derived_speed / derived_health / derived_flee_multiplier / body_mass`,
`to_dict() / from_dict()`, `species_name()` (seeded syllables).

**Derived stats are the evolution bridge**: leg length, gait frequency and
stride raise speed; body volume raises health but taxes speed; wings trade
leg speed for flight. Morphology drives fitness, so selection acts on
bodies, not cosmetics.

### 3.2 CGenome — the ECS component

`CGenome` follows the `CAgent`/`CBody` pattern exactly: `RefCounted`,
`COMPONENT_ID = &"CGenome"`, plus cached `derived_move_speed /
derived_health_max / derived_flee_multiplier / species` computed once at
assignment (`CGenome.from_genome(...)`, `CGenome.random(rng)`). Systems
copy the cached values into `CAgent.move_speed` and `CHealth.max_hp` at
spawn — the same fields the existing simulation already selects on.

### 3.3 BreedingSystem — evolution as a SIM-phase system

`BreedingSystem` is a standard `RefCounted` system with
`tick(world, delta, frame)`, registered in the SIM phase (priority 55,
after vitality, before view sync). Each half-second pass:

1. Iterates the `CGenome + CAgent + CTransform` query cache (all tiers,
   via the scratch buffer — structural changes are deferred).
2. Finds same-species adult pairs within `partner_radius`, both off the
   `breed` cooldown (tracked in `CAgent.cooldowns`, ticked here so worlds
   without utility AI still work).
3. Spawns each child **through the command buffer** —
   `world.commands.spawn_with([CTransform, CVelocity, CAgent, CHealth,
   CBody, CElemental, CGenome])` — with `CritterGenome.crossover(...)` +
   `mutate(...)`, and the child's agent/health seeded from its derived
   stats.
4. Publishes `critter_bred {child, parents, position, species, speed}` on
   the world event channels, which `EcsSystem` already forwards to
   `SystemBus` for FX/HUD.

Population cap, cooldowns, radius and mutation rate are plain exported
plumbing on `EcsConfig`. Speciation stays clean because pairing is
same-species only: each lineage drifts independently.

### 3.4 CritterBodyBuilder — genome → rigged body

`CritterBodyBuilder.build(genome) -> Node3D` returns a `"Critter"` root
(facing +Z, matching `FaunaSystem`'s `atan2(dir.x, dir.z)` heading):

- **One continuous body surface (`CritterTorso`)** — the Spore property
  that matters most. The whole body line (tail tip → spine → neck →
  skull → snout tip) is a single swept tube: control points ride the rig
  joints, a Catmull-Rom spline smooths the line and the radius profile,
  and parallel-transport frames keep the sweep twist-free. No separate
  blob meshes that can gap apart at awkward gene combinations — the body
  is always connected, and it re-skins when joints bend, so it flexes
  fluidly instead of articulating in parts.
- Coat genes are painted as **vertex colors** on that one surface:
  belly gradient from the ring direction, stripes from the position
  along the body (SPOTS stays as accent blobs on the back).
- `SpineRoot/S0..Sn` — the joint skeleton (arch + taper genes shape the
  tube radii); standing height comes from leg reach × stance, so bodies
  without legs belly-drag.
- Head parts (eyes, ears, horns, nose) ride the Head joint; the skull and
  snout surfaces belong to the torso sweep, so the face melts out of the
  body like a Spore creature.
- `Leg_F/R×L/R` hip joints on spine segments (front pair near the head,
  rear pair on the tail segment) with splay rotation → upper capsule →
  knee joint (rest `knee_bend`) → lower capsule → foot. High `knee_bend`
  = crouched digitigrade; near zero = upright column leg. A **shoulder
  bulge** sphere overlaps the tube so limbs blend into the torso.
- Tapering tail is part of the torso sweep; `WingL`/`WingR` pivots are
  named exactly like the existing bird/bat content (FaunaSystem flap
  compatibility), each rooted with a blend bulge.
- Joints register in groups (`critter_hip/knee/spine/tail/head/wing`)
  with side/pair metadata; groups survive `duplicate()`.

Re-skinning is change-triggered: `CritterGait` asks the torso to rebuild
only when a control joint actually rotated past ~0.004 rad, so idle
critters cost nothing and walking critters rebuild a few hundred vertices
(one `ArrayMesh` per body). The builder is tree-independent — buildable
and assertable in headless tests.

### 3.5 CritterGait — procedural animation

A `CritterGait` node set up by the builder (rest poses captured from the
built rig, so genome rest angles live in the rest transform) with
`tick(delta, speed_ratio)`:

- Leg cycle (FK, Spore-style): `hip.rot.x = rest + sin(phase + offset) ×
  stride`, `knee.rot.x = rest + lift(phase)`. Phase offsets per gait
  pattern gene: walk (lateral sequence), trot (diagonal pairs), pace
  (same-side pairs), bound (front vs rear + hop).
- Spine lateral wave traveling rearward; head bob at 2× stride frequency;
  tail wag wave; wings flap at double phase (hover at idle).
- Idle layer: breathing + gentle sway that fades out as `speed_ratio`
  rises. `speed_ratio` maps to simulation state — 0 idle, ~0.5 wander,
  1 flee/chase.

No baked clips exist anywhere; a mutated body animates correctly the
moment it is built. This is the core Spore property the system preserves.

### 3.6 CritterView + ViewSyncSystem — the view bridge

`CritterView extends EntityView` (the only place ECS data touches the
scene tree, per doctrine):

- `ViewSyncSystem.tick` now also pushes, one-way, the entity's `CGenome`
  (rebuilding the body only when the genome seed changes) and a motion
  ratio `|CVelocity| / CAgent.move_speed` into `CritterView`.
- The view's `_process` ticks its gait with that ratio (or a forced
  `demo_speed_ratio` for lab treadmills).
- Procedural bodies own their materials, so the generic tint/elemental
  override is disabled for them — elemental states still reach them
  through simulation effects (e.g. frozen halts `CVelocity`), and
  material-level burning/char tinting is a documented phase-2 hook.

## 4. Evolution loop

Two forces, both running on real ECS machinery:

- **Natural**: `BreedingSystem` reproduces nearby same-species adults;
  children inherit crossover + mutation genomes. Predators, hunger and
  chemistry (the existing simulation) then filter them — anything that
  makes a genome faster or tougher compounds across generations.
- **Artificial (lab proof)**: the lab's selection round scores the runway
  population by derived speed (with performance noise), despawns the
  bottom half through `world.commands`, and refills with crossover
  children of the survivors. Leg length, gait frequency and stride
  visibly climb within a few generations — the same operators production
  breeding uses, just with an explicit fitness function.

## 5. Test environment

`scenes/body_lab.tscn` — open directly (F6) or press **B** in the main
scene (ESC returns).

- Runs a real `EcsWorld` + `EcsScheduler` with **production systems**:
  `MovementSystem` (bounds-clamped), `BreedingSystem` (live demo
  reproduction), `ViewSyncSystem` — plus a lab wander driver registered
  as an ordinary SIM-phase callable, standing in for utility AI.
- **Showcase pedestals**: three genome entities; `1/2/3` select, `R`
  randomize, `M` mutate, `C` crossover slots 1+2 → child into slot 3,
  `SPACE` treadmill, `G` idle/walk/run, `TAB` cycle gait pattern gene.
  `Label3D`s show species, generation, speed; the HUD shows the full
  genome summary.
- **Evolution runway**: 8 walkers with real `CVelocity`-driven gaits;
  `E` runs a selection round, `P` auto-evolves every 5 s, the runway
  label tracks generation / best / average speed.
- **Headless smoke mode**: `BODY_LAB_SMOKE=1` self-checks population,
  bindings, mutation drift and a full evolution round, exiting non-zero
  on failure — CI-friendly without a renderer.
- Unit tests (`tests/unit/test_critter_bodies.gd`): gene determinism and
  clamping, crossover containment, derived-stat monotonicity (longer
  legs / faster cycles ⇒ faster), serialization round trip, `CGenome`
  store + query behavior, breeding child production + population cap +
  event publish, builder topology (hip/knee/spine/tail counts, WingL/R),
  gait phase tables and FK evaluation.

## 6. Deployment path into the world

Already wired, **off by default** (`EcsConfig → Procedural Critters`):

- `procedural_critters` — `EcsSystem._spawn_critters` attaches a
  randomized `CGenome` per critter, seeds `CAgent.move_speed` and
  `CHealth.max_hp` from derived stats, and binds a `CritterView` instead
  of the capsule view.
- `breeding_enabled` (+ radius / cooldown / cap / mutation-rate exports)
  — registers `BreedingSystem` in the scheduler.

Rollout checklist:

- [x] Phase 1 (this change): sim + view + lab + tests; main scene gains
      only the **B** portal; world behavior unchanged with flags off.
- [ ] Visual QA in the lab (top-down RTS angle: gaits readable,
      silhouettes distinct, no z-fighting or floating feet).
- [ ] Phase 2: flip `procedural_critters` (+ `breeding_enabled`) in the
      inspector, QA in the live world; add elemental material states to
      procedural bodies; FaunaSystem entries get an optional genome flag
      so the chunk-spawned deer/rabbits use the same pipeline
      (`create_instance()` → builder).
- [ ] Phase 3: gait cadence follows processing tiers (full FK near,
      bob-only far) — matches the tiered-processing doctrine.
- [ ] Phase 4 (only if needed): `Skeleton3D` skinned bodies generated
      from the same genome.
