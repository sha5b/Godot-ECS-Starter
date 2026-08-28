# Architecture Review

A review of the ECS layer and the world systems around it, against the three
goals in [Design Doctrine](DESIGN_DOCTRINE.md): **Godot-native**,
**inspector-first**, **easy to extend with new content**.

Findings are ordered by how much they cost you. Each one says what was
measured, not just what looked wrong. Items marked **FIXED** were changed in
this pass; items marked **OPEN** are diagnosed but not done.

---

## 1. The central problem: two actor runtimes

**RESOLVED for animals — see §1a and §1b. Vegetation is still split; shelters,
tribes and territories still have no ECS equivalent.**

The project contains two complete, unconnected implementations of "living
things in the world":

| | `systems/ecs/` | `systems/fauna/` |
|---|---|---|
| Size | ~2000 lines over 20 files | 1856 lines in one file |
| Model | components in sparse sets | `Node3D` + a `Dictionary` per actor |
| Scheduling | phases, command buffer, 4 tiers | one `for` loop per frame |
| Tests | 77 unit tests | none |
| Genetics | `CGenome`, crossover + mutation | none |
| Biome-aware spawning | **none** | yes |
| Predator / prey | **none** | yes |
| Group behaviour | **none** | flocks, tribes, territories, shelters |
| Chemistry | yes | none |

Verified by grep: `systems/ecs/` contains no occurrence of `biome`,
`predator`, `prey`, `flock`, or `herd`.

So the **evolution** lives in one system and the **ecology** lives in the
other, and neither can see the other. A genome-driven critter cannot be a
wolf, and a wolf cannot evolve. Both spawn into the same chunks, so the world
carries two populations of animals that ignore each other.

The same split repeats for vegetation. Four systems draw plants:

- `FloraSystem` — MultiMesh props, own lifecycle and seed spreading
- `FoliageSystem` — shader ground cover
- `EcsSystem._spawn_chemistry_grass` — invisible chemistry bodies
- `EcsSystem._spawn_berries` — edible spheres

`FoliageSystem` reacts to ECS chemistry events to recolour burning grass, so
the invisible layer and the visible layer are already coupled by hand.

### Recommendation

Make `systems/ecs/` the only actor runtime and reduce `FaunaSystem` to a
spawner and view layer, in this order:

1. `CSpecies` — a component holding the `FaunaEntry` that produced an actor.
   Gets biome rules, diet, and predator lists into the ECS with no new data.
2. `CDiet` + a `PredationSystem` in the SIM phase, using the spatial grid
   that `ChemistrySystem` already rebuilds.
3. `CGroup` + a `FlockingSystem`, replacing `_apply_flocking_forces`.
4. Biome-gated spawning in `EcsSystem`, reading `BiomeSystem.get_biome_at_world`.
5. Delete the duplicated AI, lifecycle, and breeding from `FaunaSystem`.

Every step is independently shippable, and each one deletes more code than it
adds. Do not start it without step 1 — `CSpecies` is what makes the rest cheap.

**All five steps are now done.** §1a covers step 1 and the genetics bug it
uncovered; §1b covers steps 2, 3 and 5.

---

## 1a. Fauna genetics: the evolution engine had never run

**FIXED.** Step 1 of the migration above, plus the bug it uncovered.

Species identity came from `CritterGenome.species_name()`, which derives from
the genome's random seed stamp — and `crossover()` gives every child a fresh
stamp. So:

```
[probe] 12 random critters -> 12 distinct species
[probe] two spawned critters same species? false
[probe] child species == parent A?        false
```

Every animal was its own species. `BreedingSystem`'s same-species gate could
never pass, so **nothing in the world had ever bred**. The whole evolution
layer — crossover, mutation, derived stats, generation counters — was inert,
and untested, so nothing said so.

### What was built

- **`CSpecies`** — the bridge component. Species id, generation, and how far
  this individual has drifted from its species body plan. Deliberately tiny:
  everything shared by a species lives once in the registry.
- **`SpeciesRecord` / `SpeciesRegistry`** — founding species come from
  `FaunaEntry` content scenes; the registry grows on its own after that.
- **`FaunaEntry` genetics group** — `genome_archetype` (grazer / runner /
  pouncer / serpent / glider), `genome_variance`, `genome_mutation_rate`,
  `speciation_distance`, `interbreed_distance`.
- **`CritterGenome.founder_for_species()`** — a species' body plan derived
  deterministically from its name, so every deer is built on the same plan and
  individuals vary *around* it. `randomized()` rolls the archetype by weight,
  which is right for a lucky-dip critter and wrong for a species.
- **`CritterGenome.distance_to()`** — normalized per-gene distance, each gene
  divided by its own legal span. Without that normalization the count genes
  (body segments spans 2–7) would drown out every proportion and angle (eye
  size spans 0.05–0.16), and "genetic distance" would only measure how many
  legs two animals disagree about.
- **Biome-gated species spawning** in `EcsSystem`, reading `FaunaSystem`'s
  authored entries through a new public `get_entries()`. The ECS used to spawn
  one anonymous critter type everywhere, with no idea biomes or species existed.

### Speciation, and the failure in the middle of it

The first working version measured each child against the species founder and
split it off if it was past the threshold. Measured: **1056 splits from 1558
births** — 70% of children founding a species, `deepest generation reached: 0`.
That is the original bug again with tidier names.

The fix is to ask whether the *lineage* has moved, not whether one child is
odd. A child now splits off only when it is past `speciation_distance` **and
both parents had already drifted most of the way there** — which is how
speciation actually works: a population diverges, a mutant does not.

Measured after, same run parameters:

| | before the fix | after |
|---|---|---|
| Births | 1558 | 2124 |
| Splits | 1056 (68%) | 92 (4.3%) |
| First split at generation | 2 | 15 |
| Deepest generation reached | 0 | 40 |

### Coverage

`tests/unit/test_species.gd` — 17 tests over founder stability, archetype
selection, distance normalization, registry behaviour, the lineage-commitment
rule, prey lists surviving speciation, and breeding through the ECS. The suite
went from 77 to 93 tests. `test_breeding_produces_offspring` asserts zero
births against the old behaviour, so the original bug cannot come back quietly.

Steps 2, 3 and 5 followed — see §1b.

---

## 1b. Predation, herds, and one simulation instead of two

**FIXED.** Steps 2, 3 and 5 of the migration.

### What was built

- **`EcsActorIndex`** — one spatial grid over living actors, rebuilt on a
  coarse timer. Predation and flocking ask the same question ("which animals
  are near this one, and what are they?"), and would otherwise each build and
  refill their own grid every tick.
- **`PredationSystem`** — resolves the bites the AI committed to, then senses
  prey and predators for next frame. Runs after the AI, because the AI writes
  INTENT and a system resolves it — the same split as the AI writing velocity
  and `MovementSystem` integrating it. Putting the damage rules in the brain
  would make every new predator behaviour a rules change.
- **`CGroup` + `FlockingSystem`** — Reynolds' three rules over the shared
  index. Groups are not authored rosters; they are whatever same-species
  animals happen to be near each other.
- **`hunt` and `evade` actions**, plus `PREY_PROXIMITY` / `PREDATOR_PROXIMITY`
  sensor inputs and a `predator_brain()` chosen from the species' diet.
- **Ecology authored into the nine content scenes** — diets, prey lists, body
  archetypes and herd weights. They were all at defaults, so predation and
  flocking would have had nothing to act on.

### Two design errors worth recording

**Hunting had to be bounded by appetite, not opportunity.** `hunt` is scored
by hunger AND prey proximity, so a fed predator ignores a herd it is standing
in. Scored on proximity alone, one wolf lineage clears the map.

**Breaking formation had to be absolute.** The first version scaled flocking
influence down to 15% for fleeing animals. That is not enough: the blend
converges on its steering target, so even a small correction applied every
tick eventually turns the animal round. Measured — an animal sprinting away
from its herd at 4 m/s was down to 1 m/s and still turning after two seconds.
A deer that cannot leave its herd cannot escape a wolf. Animals in `panic`,
`evade` or `flee` now skip flocking entirely.

A third bug nearly shipped silently: a flocking test passed while flocking was
not running at all, because it compared a `float32` velocity component against
the same value as a `float64` literal. The assertion now uses a margin.

### One population

`FaunaConfig.simulate_locally` defaults to **off**. FaunaSystem is the content
library and the ECS spawns from its entries — biome-gated, honouring each
entry's `max_per_chunk`, weighted by `spawn_weight`. Measured in the live
world: one population of 14 animals across 5 species where there used to be
two populations ignoring each other.

`FaunaEntry.use_procedural_body` picks the look per species: the genome-driven
body, so evolution is visible, or the mesh children authored in the scene.

### Coverage

`tests/unit/test_ecology.gd` — 12 tests over prey sensing, prey lists
surviving speciation, bite reach and cooldown, kill events, predator and prey
decision-making, herd cohesion and separation, species-exclusive herds, and
formation breaking. Suite: 77 → **107**.

### Two unbounded dictionaries

Found by streaming chunks in a loop and printing what kept growing
(`.qa/leak_probe.gd`), after a report of memory climbing in a long session:

```
[leak] round 1  entities=1452 animals=199  breeding_age=199
[leak] round 2  entities=716  animals=94   breeding_age=293
[leak] round 3  entities=0    animals=0    breeding_age=293   <-- never falls
```

- **`BreedingSystem._age`** was only ever added to, so every animal that had
  ever existed left a permanent entry. Chunk streaming despawns and respawns
  constantly, so it grew for as long as the game ran. Now rebuilt from the
  living population each pass. (Pre-existing, not introduced by this work.)
- **`SpeciesRegistry`** never dropped a lineage. Every split minted a record
  holding a full genome, and one probe run produced 1057 records from 1558
  births. Extinct lineages are now pruned on the stats tick; founding species
  from content are never pruned, since a biome the camera has not visited yet
  legitimately has none of them alive.

Everything else recycled correctly — entity count, view nodes and view
bindings all returned to zero when the loaded field was streamed away.

`test_extinct_lineages_are_pruned` and
`test_breeding_age_bookkeeping_follows_the_living_population` lock both down.

### Still open

Shelters, tribes, territories and buildings are driven by FaunaSystem's local
simulation and go dormant while `simulate_locally` is off. They have no ECS
equivalent — that is the next migration, and the flag flips back in one
inspector click until it exists.

---

## 2. `priority = 40` on `EcsSystem` never applied

**FIXED.**

`ecs_system.tscn` listed the property *before* the `script` line:

```
[node name="EcsSystem" type="Node"]
priority = 40                       # set on a plain Node — silently dropped
script = ExtResource("1_ecs")       # script attached afterwards
```

Godot applies scene properties in file order. `priority` is declared by
`BaseSystem`, which was not attached yet, so the assignment went nowhere.
Verified by loading the scene headless: `priority` read back as `0`.

The consequence: `EcsSystem` sorted *first* in `WorldECS`, ahead of
`ChunkManager` (-100), terrain, and biomes — the opposite of the documented
data flow. Fixed by ordering `script` first, and the root is now `Node3D` so
that the `EntityView` nodes it parents live in a real 3D hierarchy.

**Worth knowing:** this class of bug is silent. A one-line `awk` over every
`.tscn` found exactly one instance, and it had been shipping.

---

## 3. Systems reached into each other's private methods by string

**FIXED.**

Nineteen call sites used `has_method("...")` to call across systems, several
of them targeting private methods:

```gdscript
if not _terrain_for_normals.has_method("_sample_loaded_surface_height"):
    return INF
return _terrain_for_normals._sample_loaded_surface_height(wx, wz)
```

`NavigationSystem` went further and read a private dictionary by name:

```gdscript
var meshes: Dictionary = terrain_sys.get("_chunk_meshes")
```

Renaming `_sample_loaded_surface_height` would not have failed to compile. It
would have made every critter in the world silently stop being grounded, and
every foliage instance lose its surface normal — at runtime, with no error.

Fixed by promoting the three probes to a documented public API on
`TerrainSystem` (`sample_surface_height`, `sample_surface_normal`,
`get_chunk_mesh`) and giving every consumer a typed reference. All nineteen
`has_method` guards are gone; the null checks that provided graceful
degradation are kept.

---

## 4. `@export` on autoload scripts is invisible

**FIXED.**

`GameConfig` declares fifteen `@export` properties — seed, chunk size, load
radius, game speed, debug flags. Godot cannot show an inspector for a *script*
autoload, so not one of them was editable or savable from the editor. The
project's most important tuning surface was reachable only by editing GDScript.

Fixed by autoloading `autoloads/game_config.tscn` instead of the `.gd`.
Selecting the root node in that scene now exposes every value, and edits
persist in the scene file. No call site changed.

---

## 5. Input was hardcoded, and one script built its own InputMap at runtime

**FIXED.**

There was no `[input]` section in `project.godot` at all. Cameras compared
`physical_keycode == KEY_W`, and `third_person_player.gd` had a 30-line
`_ensure_input_actions()` that called `InputMap.add_action` on every startup —
building at runtime the thing Project Settings exists to hold.

Fixed: 26 actions defined in Project Settings (`world_pan_*`, `world_orbit_*`,
`world_zoom_*`, `sim_lightning`, `sim_rain`, `debug_*`, `player_*`) and every
call site converted to `Input.get_axis` / `event.is_action_pressed`. The
runtime `InputMap` builder is deleted. Rebinding is now a settings edit.

`scenes/body_lab.gd` still reads raw keycodes. It is a developer lab with
twelve debug keys and converting it would add noise for no gain.

---

## 6. Content scenes could not be edited as 3D objects

**FIXED.**

Every flora, fauna, and biome content scene had a plain `Node` root, with
`MeshInstance3D` children hanging off it. `FloraEntry` and `FaunaEntry`
extended `Node`.

A `Node` root has no transform. You cannot move, rotate, or scale the prefab,
gizmos do not apply to it, and it cannot be dragged into a 3D scene as an
object. For a project whose stated goal is "drag the `.tscn` in and you are
done", the content type was the one thing you could not manipulate.

Fixed: `FloraEntry` and `FaunaEntry` now extend `Node3D`, and all 26 flora and
fauna content scene roots were retyped. `BiomeData` stays a `Node` — it holds
climate numbers and no geometry, so a transform would be noise.

---

## 7. Adding content required editing system code

**FIXED.**

Two places made new content silently misbehave unless you also edited GDScript.

**`FloraSystem` had a hardcoded name list:**

```gdscript
const SHADER_GROUND_COVER_ENTRIES := {
    &"grass": true, &"flower": true, &"alpine_flower": true,
}
```

Any entry whose `entry_name` matched was skipped by the flora renderer. Name a
new plant `grass` and it never appears, with no warning. Replaced by an
`@export var drawn_by_foliage_shader` on `FloraEntry`, set on the three
scenes that need it.

**`FoliageSystem` had four `match biome_name:` tables** covering lushness,
dryness, scale, density bonus, and sprite weights — 14 hardcoded biome names.
A new biome scene grew ground cover from the fallback branch until someone
edited the renderer.

Moved onto `BiomeData` as a "Ground Cover" export group, with the previous
values written into the 11 biome scenes that had them, so behaviour is
unchanged and the renderer no longer knows any biome by name.

---

## 8. Every noise layer silently ran five octaves

**FIXED. Largest visual impact of the pass.**

`FastNoiseLite` defaults to `FRACTAL_FBM` with 5 octaves. Layers meant to be
smooth macro fields never set `fractal_type`, so they were not macro fields:

| Layer | Base frequency | Top octave (5 oct, lacunarity 2) |
|---|---|---|
| continent | 0.0015 | **0.024** |
| detail | 0.012 | 0.19 |
| valley | 0.003 | 0.048 |
| temperature | 0.005 | 0.08 |
| moisture | 0.007 | 0.11 |

The continent field's top octave was **finer than the detail layer's base
frequency**. Nothing in the pipeline produced continent-scale structure, which
is the whole reason the world read as scattered blobby islands.

The climate fields had the same problem at metre scale, which is what speckled
the biome map.

Fixed by setting `fractal_type` and octave counts explicitly everywhere, with
`continent_octaves` and `climate_octaves` exposed in the inspector.

---

## 9. Terrain had no continents and no mountain ranges

**FIXED.** Measured before and after with `.qa/height_profile.gd`.

The old height function was `continent * 0.5 + detail * 0.5 + ridged`, all
summed as equals. Summing symmetric noise gives a symmetric height
distribution, then four separate passes flattened whatever relief survived.

Measured over 4096 m × 4096 m, seed 42:

| | before | after |
|---|---|---|
| Land fraction | 59.8% | 40.0% |
| Peak height | 29.6 m | 42.3 m |
| Land in lowest elevation decile | 19.7% | 35.2% |
| Land in top two deciles | 0.4% | — (long tail) |
| Median land slope | 24.1° | 14.7° |
| 99th percentile slope | 50.7° | 46.3° |

Before: no flat ground anywhere (median slope 24°), no high ground anywhere
(top deciles empty). Uniform moderate lumpiness from horizon to horizon.
After: a long-tailed hypsometric curve — plains are common, peaks are rare,
which is what real elevation histograms look like.

What changed:

- **Continentality with a solved threshold.** The sea level in continent-noise
  units is solved at startup from the field's own quantiles, so
  `continent_land_fraction = 0.38` produces 38% land on any seed.
- **A land mask** ramping from the coastline inland, so coasts meet the sea at
  sea level instead of stepping out of it.
- **A power curve on land elevation** (`land_elevation_power`), which is what
  turns "hills everywhere" into "plains with occasional mountains".
- **Orogeny belts.** Mountains now only rise inside belts taken from the zero
  crossings of a very low frequency field — `1 - |noise|` selects continuous
  curved bands, so ranges are chains with passes and foothills. 22.8% of land
  falls inside a belt.
- **Erosion that respects relief.** Thermal erosion fades out above
  `thermal_high_ground_start`, walkability enforcement is skipped above
  `walkable_max_normalized_height`, and plateau flattening is skipped inside
  orogeny belts. Previously all three planed off exactly the ridgelines that
  give a landscape a skyline — and plateau flattening took a *bigger* cut the
  taller the mountain.
- `grid_max_y` raised 40 → 48 so summits are not sliced by the density volume.

---

## 10. Water shaders lived in GDScript strings

**FIXED.**

`water_system.gd` and `river_system.gd` each returned their shader as a ~190
line GDScript string literal, while terrain, clouds, foliage, and the
underwater effect all used real `.gdshader` files. String shaders get no
syntax highlighting, no error lines that point at the shader, no hot reload,
and cannot be assigned in the inspector.

Both are now real files, sharing `systems/water/water_common.gdshaderinc`.
That include is also what makes a river mouth and the sea it runs into the
same material family instead of two lookalikes with separate palettes.

---

## 11. The ocean read as corduroy

**FIXED.** This took three attempts and the failures are worth recording.

The original `wave_normal()` summed six directional sine waves. A short sum of
sines is exactly periodic and every component is a straight-crested plane
wave, so open water showed a hard diagonal lattice at every camera angle.

**Attempt 1 — more sines, rotated and domain-warped.** Still stripes.
Rotating plane waves changes the angle of the corduroy, not the fact of it.

**Attempt 2 — translate a noise field.** Stripes gone, but it read as a
texture sliding sideways, because a real wave does not carry the water with
it: the surface orbits in place while the *phase* propagates.

**Attempt 3 — Gerstner waves with noise-bent crests.** Vertical
`A·sin(θ)` plus horizontal `−dir·A·cos(θ)`, so the surface rolls and crests
come out narrow over broad troughs. Each component's phase is bent by a
slowly-varying noise field, so crests are long curved ridges rather than ruler
lines. `ω = √(gk)` means long swell outruns short chop and the sea state never
repeats in view.

Three separate bugs found along the way, each worth stating plainly:

- **Steepness vs amplitude.** Surface slope is `A·k`, so a fixed amplitude
  makes short waves arbitrarily steep — 0.55 m on a 6.5 m wave is a slope of
  0.53, a 28° tilt at every crest. Five of those summed produced the
  interference pattern. The parameter is now dimensionless steepness; real
  wind chop sits near 0.1 and gravity waves break at 0.44.
- **Harmonic components.** Halving wavelength per octave makes the components
  harmonics of each other, and harmonics beat into visible moiré. Now 0.593.
- **Normal aliasing.** 6.5 m chop viewed at 150 m is sub-pixel, and at grazing
  angles a pixel covers many crests. Detail normals now fade to flat between
  `chop_fade_start` and `chop_fade_end`, which is also what real distant water
  looks like.

**Performance.** The first noise version ran a 5-octave FBM per *vertex* on
water planes subdivided to 128×128 — a vertex every 25 cm, for a 110 m swell.
That measured **2 fps**. Displacement now runs two components, subdivision is
32 (a vertex per metre), and the far-ocean ring's 8 triangles are excluded from
displacement entirely — displacing them produced enormous flat facets, not
waves. Measured after: **111–149 fps** on open water at `load_radius = 6`.

---

## 12. The sea ignored the weather

**FIXED.**

`wind_dir` was a shader uniform that nothing ever wrote. Every wave component
fanned around the same fixed easterly bearing for the whole game, which is why
all waves ran one way regardless of the wind on the HUD.

`WaterSystem` now pushes `wind_dir`, `sea_state`, and `rain_intensity` from
`SharedWorld` every frame, eased over time: the sea builds under a rising wind
at `sea_build_rate`, lays down more slowly at `sea_calm_rate`, and the wave
bearing swings round at `sea_turn_rate`. A swell outlives the wind that raised
it, and can run across the wind for a while after it shifts.

Downstream of sea state: wave steepness, whitecap coverage (breaking only
above roughly force 4), and surface roughness. Rain adds its own short
isotropic ripple field.

---

## 13. There was no shore break

**FIXED.**

The surf was `sin(world_pos.z * 1.5 - time * ...)` — a fixed world-space
diagonal, so breakers ran at the same angle across every bay in the world, and
the "foam" was a static band at a fixed depth.

Replaced with a real model, all from depth plus noise plus time:

- **Shoaling** — Green's law, amplitude ≈ depth^(−1/4), capped.
- **Breaking** — when wave height over depth passes `shore_break_ratio`
  (real value ≈ 0.78).
- **Foam with a trail** — sharp front, long decaying tail, so whitewater is
  left *behind* a wave instead of travelling with it.
- **Swash** — the sheet running up the sand and draining back.

Wavefronts use depth as the phase variable, so breakers arrive parallel to the
shore whatever shape it is, with a noise term to keep the line ragged.

The waterline itself now feathers rather than ending on a hard cut, and the
softness band is scaled by viewing angle — `depth_diff` is a *view-space*
distance, and a fixed band erased whole bays at grazing angles.

Also fixed: the terrain depth texture was sampled at raw UV 0..1 while its
outer texels sit *on* the chunk boundary, so neighbouring chunks disagreed
along every shared edge. Half-texel inset sampling removed that seam grid.

---

## 14. Rivers were ribbons painted on cliffs

**PARTIALLY FIXED.**

Terrain deliberately reduces its river carve on steep ground
(`river_cliff_protection_slope`, `river_cliff_depth_scale`). The renderer did
not know that, so where no channel existed it drew the water surface at
`bed_y + water_lift` — a flat ribbon lying on a 40° hillside. It read as a
white stripe painted down the mountain.

Two fixes:

- **No channel, no surface.** A surface is only emitted where the terrain
  actually carved at least `min_channel_depth`. Elsewhere the path breaks and
  resumes. Water on that gradient is a cascade; leaving the gap is closer to
  the truth than painting a ribbon.
- **Bank foam scaled by real width.** The foam band was a fixed *UV* fraction
  (0.08–0.30), so a two-metre creek was 60% foam — which is why every narrow
  river rendered solid white. It is now a width in metres.

Plus the outlet: the river surface was clamped up to sea level at the mouth,
landing exactly coplanar with the ocean plane. Two coplanar transparent sheets
z-fight and read as a seam between two different waters. The river now sinks
fractionally and fades out across `outlet_blend_distance`, letting the ocean
take the last metres.

**OPEN — the real river work.** What is there is still a traced path with a
carved trench, not hydrology. To get rivers that behave:

- **Flow accumulation** (D8 or D-infinity over the macro height field) instead
  of per-chunk source noise. Width and depth then follow discharge, so rivers
  grow downstream, tributaries merge, and they always reach the sea.
- **Cascade geometry** for the steep sections currently skipped — a waterfall
  is a mesh, not a gap.
- **Estuary widening** at the mouth rather than a fade.

Flow accumulation is the single highest-value item: it replaces source
placement, width, depth, and confluence handling with one derived quantity.

---

## 15. Biome classification rewarded vagueness

**FIXED.** Measured with `.qa/biome_map.gd` over 4096 m.

`score()` measures distance relative to *each biome's own tolerance*. That
quietly rewards claiming a wide envelope: `cave_interior`
(tolerances 0.5 / 0.5 / 0.5) scores near 1.0 across half the climate space and
beats a specialist like `forest` (0.25 / 0.25) everywhere the specialist is not
sitting exactly on its ideal.

Measured share of a 4096 m region:

| Biome | before | after |
|---|---|---|
| beach | 18.9% | 1.0% |
| cave_interior *(on the surface)* | 6.6% | 0% |
| plains | 4.8% | 20.9% |
| tundra | 5.2% | 9.6% |
| taiga | 6.4% | 8.5% |
| forest | 0.4% | 2.1% |
| coral_reef | 0.0% | 2.1% |

Four changes:

- **Specificity weighting.** Scores are weighted by the inverse of the climate
  envelope, so a narrow niche wins inside its niche while generalists still
  pick up the leftovers. Height is excluded from the weighting — an altitude
  band is a physical constraint, not a claim about pickiness.
- **`surface_biome` flag** on `BiomeData`, off for `cave_interior`. A cave
  biome should not compete for open ground.
- **Domain-warped climate lookup.** Two extra noise samples displace where
  each point reads the climate from, turning compass-drawn borders into
  meandering fractal-edged ones. `climate_warp_strength` is the wiggle size.
- **Ecotone interleaving.** Where two biomes score within `ecotone_blend` of
  each other, a stable hash picks between them, so the border is a belt where
  the two interlock rather than a line — the way a treeline meets a meadow.
- **Nearest-biome fallback.** `score()` returns exactly 0 outside tolerance,
  and the old loop then fell through to whichever biome was listed first,
  producing arbitrary patches of it. `affinity()` ranks the nearest instead.

`get_biome_at_world` now uses the same warped path and the same ecotone rule as
the chunk map. It did not before, and terrain vertex colouring reads it — so
ground colour disagreed with the flora standing on it.

---

## 16. Smaller findings

**FIXED**

- **`ChunkData.get_resolution()` took a square root on every call**, and
  `sample_height()` went through it — so one bilinear probe cost four square
  roots, in the loops that place every plant, critter, and nav cell in a
  chunk. Resolution is now cached when the heightmap is assigned.
- **`sample_biome()` could index past the end of `biome_map`**, because the
  resolution comes from the heightmap and a chunk whose biome pass has not run
  yet has an empty one. Now returns 0.
- **`BreedingSystem` was the one non-deterministic part of the simulation.**
  It allocated a fresh `RandomNumberGenerator` every tick seeded from
  `Time.get_ticks_msec()`, so a fixed `world_seed` could not reproduce an
  evolutionary run. Now one RNG for the system's lifetime, seeded from
  `GameConfig.world_seed`.
- **Fog washed out the world.** `fog_density` 0.0012 plus volumetric fog made
  terrain 55 m away pale and flat, which hid all the terrain detail. Halved,
  with `fog_aerial_perspective` added so distance still reads.

**OPEN**

- **`SystemBus` has 35 signals**, many of them one-consumer implementation
  details (`tribe_created`, `building_abandoned`, `fauna_group_updated`). The
  doctrine says a bus signal should be a meaningful cross-system event. Most of
  these are internal to `FaunaSystem` and would disappear with finding 1.
- **`FaunaSystem` is 1856 lines with ~20 responsibilities** — spawning, groups,
  tribes, parenting, shelters, buildings, territory, AI, movement, flocking,
  navigation, lifecycle, foraging, breeding, animation, and visuals. The
  doctrine's own golden rule ("if a new system cannot be described in one
  sentence, it is probably doing too much") condemns it.
- **`GameConfig._ready()` sets `Engine.time_scale`**, which slows everything
  including UI. `rts_camera.gd` has to divide it back out to feel normal. A
  simulation-speed multiplier applied in `WorldECS.system_process` would scale
  the world without touching the engine clock.
- **No `@tool` scripts anywhere.** Nothing in the project previews in the
  editor. A `@tool` on `FloraEntry` that showed its footprint radius, or on
  `BiomeData` that showed its climate envelope, would make the inspector-first
  goal real rather than aspirational.

---

## Verification

- `godot --headless --path . --script tests/run_tests.gd` — **107 passed, 0 failed**
- `godot --headless --path . res://scenes/main.tscn` — clean, no script or
  shader errors
- `.qa/height_profile.gd` — elevation, slope, and belt-coverage statistics
- `.qa/biome_map.gd` — renders the biome map as a PNG with per-biome shares
- `.qa/water_fps.gd` — frame rate over open water, worst case for the shader
- `.qa/shore_shot.gd`, `.qa/river_shot.gd` — fixed-seed visual comparison shots
- `.qa/evolution_probe.gd` — drives breeding headless and reports births,
  splits and lineage depth over thousands of generations
- `.qa/species_live.gd`, `.qa/ecology_fps.gd` — the live world's species mix,
  frame cost and predation activity
- `.qa/leak_probe.gd` — streams chunks in a loop and prints what keeps growing

The `.qa` scripts are the point, not the numbers they printed once. Every
finding above that says "measured" was measured with one of them, and they will
say whether the next change helps or hurts.
