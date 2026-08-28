# Handoff

Working notes for whoever picks this up next. What state the project is in,
what is open and in what order, and the traps that cost time last session.

Findings and measurements live in **[Architecture Review](ARCHITECTURE_REVIEW.md)** —
this file is the operational summary, not a repeat of it.

---

## Current state

- `godot --headless --path . --script tests/run_tests.gd` → **107 passed, 0 failed**
- `godot --headless --path . res://scenes/main.tscn` → clean, no script or shader errors
- Working tree clean at `3e979f3`

The ECS is now the only thing that simulates animals. `FaunaSystem` is the
content library (`get_entries()`); `EcsSystem` spawns from its `FaunaEntry`
scenes, biome-gated, and runs movement, utility AI, predation, flocking,
chemistry, lifecycle, breeding and speciation on them.

Terrain generates continents with mountain belts, biomes classify with
domain-warped climate and interleaved ecotones, and water is a Gerstner
surface coupled to the weather.

---

## Open work, in the order I would do it

### 1. Shelters, tribes, territories and buildings are dormant

**This is a regression from last session, so it goes first.**

They are driven by `FaunaSystem`'s local simulation, which
`FaunaConfig.simulate_locally = false` turns off. Flipping it back on restores
them but puts two animal populations in the world again — which is exactly the
problem the migration removed.

The fix is to migrate them: `CShelter` and `CTerritory` components, placed by
the utility AI that already exists. `CSpecies` already carries the species
identity they need, and `FaunaShelterProfile` / `FaunaTribeProfile` already
author the rules.

### 2. Rivers are not hydrology

**The biggest remaining visual problem, and self-contained.**

What exists is a traced path plus a carved trench. Last session stopped the
worst artifact — flat ribbons painted down 40° cliffs where terrain never
carved a channel — but not its cause.

- **Flow accumulation** (D8 or D-infinity over the macro height field) instead
  of per-chunk source noise. Width, depth, tributary merging and reaching the
  sea all fall out of one derived quantity, replacing four hand-tuned
  mechanisms.
- **Cascade meshes** for the steep sections now skipped. A waterfall is
  geometry, not a gap.
- **Estuary widening** at the mouth instead of an alpha fade.

Flow accumulation is the single highest-value item in this list.

### 3. Vegetation is still split four ways

`FloraSystem` props, `FoliageSystem` shader ground cover, `EcsSystem`'s
invisible chemistry grass, and `EcsSystem`'s berry bushes. Same shape as the
animal problem that is now fixed — and `FoliageSystem` already reacts to ECS
chemistry events by hand, so the coupling exists informally already.

### 4. `FaunaSystem` is 1856 lines

Most of it is now unreachable behind `simulate_locally`. Once item 1 lands it
can be deleted down to a content library. Do not delete it before then — the
shelter and tribe logic is the only copy.

### 5. `SystemBus` has 35 signals

Many are one-consumer internals (`tribe_created`, `building_abandoned`,
`fauna_group_updated`). Most disappear with item 4.

### 6. Two smaller ones

- **`GameConfig._ready()` sets `Engine.time_scale`**, which slows the UI too —
  `rts_camera.gd` has to divide it back out to feel normal. A simulation-speed
  multiplier applied in `WorldECS.system_process` would scale the world without
  touching the engine clock.
- **No `@tool` scripts anywhere.** Nothing previews in the editor. A `@tool` on
  `FloraEntry` showing its footprint radius, or on `BiomeData` showing its
  climate envelope, would make "inspector-first" real rather than aspirational.

---

## How to work on this

### Measure, do not reason

Every generation and graphics change last session that *looked* right in code
was wrong on screen, and every one that got fixed was fixed by measuring. The
harnesses under `.qa/` (gitignored) exist for this and are meant to be reused
and rewritten:

| Script | Answers |
|---|---|
| `height_profile.gd` | land fraction, elevation deciles, slope percentiles, belt coverage |
| `biome_map.gd` | renders the biome map as a PNG plus per-biome share |
| `evolution_probe.gd` | births, splits, lineage depth over thousands of generations |
| `leak_probe.gd` | streams chunks in a loop and prints what keeps growing |
| `ecology_fps.gd` | frame cost, per-system microseconds, predation activity |
| `species_live.gd` | the live world's species mix |
| `shore_shot.gd`, `river_shot.gd`, `ridge_shot.gd` | fixed-seed screenshots |

Run them with:

```
flatpak run org.godotengine.Godot --headless --path . --script res://.qa/<name>.gd
```

Drop `--headless` when the script saves a screenshot. **Look at the PNG.**

### Traps that cost time last session

- **Autoloads do not exist in `--headless --script` SceneTree mode.**
  `GameConfig` and `SharedWorld` are unresolved identifiers there. Either run a
  scene instead, or reach them with `root.get_node("/root/SharedWorld")`.
- **A new `class_name` is not visible until the project reimports.** Run
  `godot --headless --path . --import` once after adding a script, or every
  reference to it fails to parse.
- **`world.query([...])` needs a typed array** when the result goes into an
  untyped `var`. Use `var required: Array[StringName] = [&"CSpecies"]`.
- **A property written before `script =` in a `.tscn` is silently dropped.**
  `priority = 40` on `EcsSystem` had never applied. Worth an `awk` sweep if
  something in a scene seems not to take effect.
- **`FastNoiseLite` defaults to 5-octave FBM.** A layer that is meant to be a
  smooth macro field must set `fractal_type` explicitly, or its top octave
  lands at detail scale and it stops being a macro field.
- **`float32` vs `float64` in assertions passes spuriously.** A flocking test
  passed while flocking was not running at all, because it compared a Vector3
  component against the same literal. Assert with a margin.
- **`pkill -f` matches your own shell.** It killed the running command twice
  last session, losing the edits queued behind it. Prefer `TaskStop`.
- **Flatpak Godot cannot read `/tmp`.** Throwaway scripts have to live inside
  the project directory.

### Doctrine that is actually enforced

- Content is authored in `.tscn` scenes and discovered, never registered in
  code. If a system needs to know a content item by name, that is a bug — see
  review §7 for two that were fixed.
- Systems talk through `SystemBus` and `SharedWorld`, and reach each other only
  through documented public APIs. `has_method("_private_thing")` duck typing
  was removed; do not reintroduce it.
- Anything a designer should tune is an `@export` on a config child or a
  content scene.

---

## Things that are easy to get wrong in this codebase

**Speciation is a population property, not an individual one.** A child splits
off only when both its parents had already drifted most of the way to the
threshold. Measuring one child against the founder makes every animal its own
species — measured at 1056 splits from 1558 births before the parent condition
existed.

**Flocking must not touch fleeing animals at all.** Reducing its influence is
not enough: the blend converges on its target, so a small correction every tick
still turns the animal round. A deer that cannot leave its herd cannot escape a
wolf.

**Wave steepness is `A*k`, not amplitude.** A fixed amplitude makes short waves
arbitrarily steep and the ocean reads as crumpled foil. Real wind chop sits
near 0.1; gravity waves break at 0.44.

**Predation must be bounded by appetite, not opportunity.** `hunt` scores on
hunger AND prey proximity, so a fed predator ignores a herd it is standing in.
Scored on proximity alone, one predator lineage clears the map.
