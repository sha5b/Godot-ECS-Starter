class_name CritterGenome
extends RefCounted

## Gene set for a procedural critter body (Spore-style).
##
## A genome is a flat map of clamped genes describing the body plan:
## structural counts (segments, leg pairs, eyes), proportions (lengths,
## girths) and — most importantly — ANGLES: rest poses (spine arch, knee
## bend, stance splay, snout droop, ear angle, tail droop) and gait angles
## (stride amplitude, knee lift, spine wave, head bob, tail wag, cycle
## speed). Genomes mutate, crossover and derive gameplay stats, which is
## what makes bodies evolve under selection instead of being decoration.
##
## All genes are stored as floats (counts included) so mutation, crossover
## and serialization stay uniform. Integer genes are rounded at read time.

const GENE_COUNT_BODY_SEGMENTS := &"body_segments"
const GENE_SEG_LENGTH := &"seg_length"
const GENE_SEG_GIRTH := &"seg_girth"
const GENE_TAPER := &"taper"
const GENE_SPINE_ARCH := &"spine_arch"
const GENE_STANCE_HEIGHT := &"stance_height"

const GENE_HEAD_SIZE := &"head_size"
const GENE_SNOUT_LENGTH := &"snout_length"
const GENE_SNOUT_DROOP := &"snout_droop"
const GENE_EYE_COUNT := &"eye_count"
const GENE_EYE_SIZE := &"eye_size"
const GENE_EAR_SIZE := &"ear_size"
const GENE_EAR_ANGLE := &"ear_angle"
const GENE_HORN_SIZE := &"horn_size"

const GENE_LEG_PAIRS := &"leg_pairs"
const GENE_LEG_LENGTH := &"leg_length"
const GENE_LEG_GIRTH := &"leg_girth"
const GENE_KNEE_BEND := &"knee_bend"
const GENE_STANCE_SPLAY := &"stance_splay"
const GENE_FOOT_SIZE := &"foot_size"

const GENE_TAIL_SEGMENTS := &"tail_segments"
const GENE_TAIL_LENGTH := &"tail_length"
const GENE_TAIL_DROOP := &"tail_droop"

const GENE_HAS_WINGS := &"has_wings"
const GENE_WING_SPAN := &"wing_span"
const GENE_WING_FLAP := &"wing_flap"

## Fins are to water what wings are to air: the gene that decides which medium
## a body lives in. Locomotion used to be an authored flag on FaunaEntry, so a
## lineage could evolve its shape, size, gait and colour but never what it
## moved through — and nothing that walked could ever give rise to something
## that swam.
const GENE_HAS_FINS := &"has_fins"
const GENE_FIN_SPAN := &"fin_span"

const GENE_HUE := &"hue"
const GENE_SAT := &"sat"
const GENE_VAL := &"val"
const GENE_BELLY_LIGHT := &"belly_light"
const GENE_ACCENT_AMOUNT := &"accent_amount"
const GENE_PATTERN := &"pattern"

const GENE_GAIT_PATTERN := &"gait_pattern"
const GENE_GAIT_CYCLE := &"gait_cycle"
const GENE_STRIDE_AMP := &"stride_amp"
const GENE_KNEE_LIFT := &"knee_lift"
const GENE_SPINE_WAVE := &"spine_wave"
const GENE_HEAD_BOB := &"head_bob"
const GENE_TAIL_WAG := &"tail_wag"

## Gait pattern gene values.
enum GaitPattern { WALK = 0, TROT = 1, PACE = 2, BOUND = 3 }

## Color pattern gene values.
enum CoatPattern { NONE = 0, STRIPES = 1, SPOTS = 2 }

## Seed this genome was generated from (drives the species name).
var seed_value: int = 0

## gene name -> value. Every gene is a float; see the range table below.
var genes: Dictionary = {}

## Generation counter — incremented on mutation/crossover by the caller.
var generation: int = 0


## ── Ranges ────────────────────────────────────────────────────────────────────
## Hard clamps so no mutation can ever produce a broken body plan.

static func _ranges() -> Dictionary:
	return {
		GENE_COUNT_BODY_SEGMENTS: Vector2(2.0, 7.0),
		GENE_SEG_LENGTH: Vector2(0.30, 0.65),
		GENE_SEG_GIRTH: Vector2(0.5, 1.5),
		GENE_TAPER: Vector2(-0.5, 0.5),
		GENE_SPINE_ARCH: Vector2(-0.35, 0.35),
		GENE_STANCE_HEIGHT: Vector2(0.7, 1.5),
		GENE_HEAD_SIZE: Vector2(0.5, 1.4),
		GENE_SNOUT_LENGTH: Vector2(0.1, 0.9),
		GENE_SNOUT_DROOP: Vector2(-0.5, 0.5),
		GENE_EYE_COUNT: Vector2(2.0, 4.0),
		GENE_EYE_SIZE: Vector2(0.05, 0.16),
		GENE_EAR_SIZE: Vector2(0.0, 0.8),
		GENE_EAR_ANGLE: Vector2(-0.6, 0.9),
		GENE_HORN_SIZE: Vector2(0.0, 0.7),
		GENE_LEG_PAIRS: Vector2(0.0, 2.0),
		GENE_LEG_LENGTH: Vector2(0.5, 1.6),
		GENE_LEG_GIRTH: Vector2(0.3, 1.0),
		GENE_KNEE_BEND: Vector2(0.15, 1.4),
		GENE_STANCE_SPLAY: Vector2(0.0, 0.5),
		GENE_FOOT_SIZE: Vector2(0.08, 0.3),
		GENE_TAIL_SEGMENTS: Vector2(0.0, 6.0),
		GENE_TAIL_LENGTH: Vector2(0.3, 1.2),
		GENE_TAIL_DROOP: Vector2(-0.6, 0.6),
		GENE_HAS_WINGS: Vector2(0.0, 1.0),
		GENE_WING_SPAN: Vector2(0.8, 2.2),
		GENE_WING_FLAP: Vector2(0.3, 0.9),
		GENE_HAS_FINS: Vector2(0.0, 1.0),
		GENE_FIN_SPAN: Vector2(0.4, 2.0),
		GENE_HUE: Vector2(0.0, 1.0),
		GENE_SAT: Vector2(0.25, 0.8),
		GENE_VAL: Vector2(0.35, 0.8),
		GENE_BELLY_LIGHT: Vector2(0.1, 0.45),
		GENE_ACCENT_AMOUNT: Vector2(0.0, 1.0),
		GENE_PATTERN: Vector2(0.0, 2.0),
		GENE_GAIT_PATTERN: Vector2(0.0, 3.0),
		GENE_GAIT_CYCLE: Vector2(0.8, 2.4),
		GENE_STRIDE_AMP: Vector2(0.25, 0.8),
		GENE_KNEE_LIFT: Vector2(0.2, 0.9),
		GENE_SPINE_WAVE: Vector2(0.0, 0.35),
		GENE_HEAD_BOB: Vector2(0.0, 0.25),
		GENE_TAIL_WAG: Vector2(0.0, 0.5),
	}


## Genes that represent discrete counts / choices — mutated by ±1 steps.
static func _int_genes() -> Array:
	return [
		GENE_COUNT_BODY_SEGMENTS, GENE_EYE_COUNT, GENE_LEG_PAIRS,
		GENE_TAIL_SEGMENTS, GENE_HAS_WINGS, GENE_HAS_FINS, GENE_PATTERN,
		GENE_GAIT_PATTERN,
	]


static func gene_range(gene: StringName) -> Vector2:
	var ranges := _ranges()
	if not ranges.has(gene):
		push_error("[CritterGenome] unknown gene '%s'" % str(gene))
		return Vector2.ZERO
	return ranges[gene]


static func clamp_gene(gene: StringName, value: float) -> float:
	var r := gene_range(gene)
	return clampf(value, r.x, r.y)


# ── Construction ───────────────────────────────────────────────────────────────


func _init(copy_from: CritterGenome = null) -> void:
	if copy_from != null:
		seed_value = copy_from.seed_value
		generation = copy_from.generation + 1
		genes = copy_from.genes.duplicate()
	else:
		seed_value = 0
		generation = 0
		genes = {}


## Body-plan archetypes. Uniform-random gene soups sample the whole
## morphospace evenly, which mostly produces mush — sampling AROUND a few
## proven plans (grazer, runner, pouncer, serpent, glider) keeps every roll
## looking like a species while leaving the genes free to drift between
## plans under evolution. Structural genes are forced to the plan; the rest
## are pulled partway toward it.
static func _archetypes() -> Dictionary:
	return {
		&"grazer": {
			"weight": 0.30,
			"genes": {
				GENE_LEG_PAIRS: 2.0, GENE_HAS_WINGS: 0.0, GENE_HAS_FINS: 0.0,
				GENE_COUNT_BODY_SEGMENTS: 4.0, GENE_SEG_LENGTH: 0.45,
				GENE_SEG_GIRTH: 1.1, GENE_TAPER: 0.1,
				GENE_LEG_LENGTH: 0.9, GENE_LEG_GIRTH: 0.7,
				GENE_KNEE_BEND: 0.5, GENE_STANCE_SPLAY: 0.12,
				GENE_SNOUT_LENGTH: 0.6, GENE_TAIL_SEGMENTS: 3.0,
				GENE_GAIT_PATTERN: float(GaitPattern.WALK), GENE_STRIDE_AMP: 0.4,
			},
		},
		&"runner": {
			"weight": 0.20,
			"genes": {
				GENE_LEG_PAIRS: 2.0, GENE_HAS_WINGS: 0.0, GENE_HAS_FINS: 0.0,
				GENE_COUNT_BODY_SEGMENTS: 3.0, GENE_SEG_LENGTH: 0.45,
				GENE_SEG_GIRTH: 0.8, GENE_TAPER: 0.0,
				GENE_LEG_LENGTH: 1.4, GENE_LEG_GIRTH: 0.5,
				GENE_KNEE_BEND: 0.35, GENE_STANCE_SPLAY: 0.06,
				GENE_SNOUT_LENGTH: 0.4, GENE_TAIL_SEGMENTS: 3.0,
				GENE_GAIT_PATTERN: float(GaitPattern.BOUND), GENE_STRIDE_AMP: 0.7,
				GENE_GAIT_CYCLE: 1.9,
			},
		},
		&"pouncer": {
			"weight": 0.15,
			"genes": {
				GENE_LEG_PAIRS: 1.0, GENE_HAS_WINGS: 0.0, GENE_HAS_FINS: 0.0,
				GENE_COUNT_BODY_SEGMENTS: 3.0, GENE_SEG_LENGTH: 0.4,
				GENE_SEG_GIRTH: 1.0, GENE_TAPER: -0.1,
				GENE_LEG_LENGTH: 1.2, GENE_LEG_GIRTH: 0.8,
				GENE_KNEE_BEND: 0.9, GENE_STANCE_SPLAY: 0.1,
				GENE_SNOUT_LENGTH: 0.3, GENE_TAIL_SEGMENTS: 4.0,
				GENE_GAIT_PATTERN: float(GaitPattern.BOUND), GENE_STRIDE_AMP: 0.65,
			},
		},
		&"serpent": {
			"weight": 0.20,
			"genes": {
				GENE_LEG_PAIRS: 0.0, GENE_HAS_WINGS: 0.0, GENE_HAS_FINS: 0.0,
				GENE_COUNT_BODY_SEGMENTS: 6.0, GENE_SEG_LENGTH: 0.5,
				GENE_SEG_GIRTH: 0.7, GENE_TAPER: -0.15,
				GENE_SPINE_ARCH: 0.05, GENE_SPINE_WAVE: 0.3,
				GENE_SNOUT_LENGTH: 0.35, GENE_TAIL_SEGMENTS: 2.0,
				GENE_GAIT_PATTERN: float(GaitPattern.PACE), GENE_GAIT_CYCLE: 1.6,
			},
		},
		&"swimmer": {
			"weight": 0.15,
			"genes": {
				GENE_LEG_PAIRS: 0.0, GENE_HAS_WINGS: 0.0, GENE_HAS_FINS: 1.0,
				GENE_COUNT_BODY_SEGMENTS: 5.0, GENE_SEG_LENGTH: 0.5,
				GENE_SEG_GIRTH: 0.9, GENE_TAPER: -0.25,
				GENE_FIN_SPAN: 1.2, GENE_SPINE_WAVE: 0.32,
				GENE_SNOUT_LENGTH: 0.3, GENE_TAIL_SEGMENTS: 3.0,
				GENE_TAIL_LENGTH: 0.9,
				GENE_GAIT_PATTERN: float(GaitPattern.PACE), GENE_GAIT_CYCLE: 1.4,
				GENE_STRIDE_AMP: 0.35,
			},
		},
		&"glider": {
			"weight": 0.15,
			"genes": {
				GENE_LEG_PAIRS: 2.0, GENE_HAS_WINGS: 1.0, GENE_HAS_FINS: 0.0,
				GENE_COUNT_BODY_SEGMENTS: 3.0, GENE_SEG_LENGTH: 0.4,
				GENE_SEG_GIRTH: 0.7, GENE_TAPER: -0.2,
				GENE_LEG_LENGTH: 0.6, GENE_LEG_GIRTH: 0.4,
				GENE_WING_SPAN: 1.8, GENE_TAIL_SEGMENTS: 4.0,
				GENE_GAIT_PATTERN: float(GaitPattern.WALK), GENE_STRIDE_AMP: 0.3,
			},
		},
	}


## Deterministic random genome from a seeded RNG. Samples around an
## archetype (see _archetypes), then applies coherence rules — flyers
## trade leg investment for wings, legless builds go long and wavy — and
## allometric floors so mass always matches its supports.
static func randomized(rng: RandomNumberGenerator) -> CritterGenome:
	var genome := CritterGenome.new()
	genome.seed_value = rng.randi()
	for gene in _ranges().keys():
		var r: Vector2 = _ranges()[gene]
		genome.genes[gene] = rng.randf_range(r.x, r.y)

	# Roll an archetype by weight, then pull the genome toward its plan.
	var roll := rng.randf()
	var chosen_name := &"grazer"
	var acc := 0.0
	for plan_name in _archetypes():
		acc += float(_archetypes()[plan_name]["weight"])
		if roll <= acc:
			chosen_name = plan_name
			break
	_apply_archetype(genome, chosen_name, rng)
	return genome


## Names of the body-plan archetypes, for inspector dropdowns.
static func archetype_names() -> PackedStringArray:
	var out := PackedStringArray()
	for plan_name in _archetypes():
		out.append(str(plan_name))
	return out


## Sample a genome around one NAMED archetype.
##
## randomized() rolls the archetype by weight, which is right for a lucky-dip
## critter and wrong for a species: a deer has to come out a grazer every
## time, or the species has no body plan.
static func for_archetype(archetype: StringName, rng: RandomNumberGenerator) -> CritterGenome:
	var genome := CritterGenome.new()
	genome.seed_value = rng.randi()
	for gene in _ranges().keys():
		var r: Vector2 = _ranges()[gene]
		genome.genes[gene] = rng.randf_range(r.x, r.y)
	_apply_archetype(genome, archetype, rng)
	return genome


## The founding genome of a species: deterministic from the species name, so
## every deer in every world on every seed is built on the same body plan and
## individuals vary AROUND it rather than replacing it.
static func founder_for_species(species_name_hint: StringName,
		archetype: StringName, world_seed: int = 0) -> CritterGenome:
	var rng := RandomNumberGenerator.new()
	rng.seed = (hash(species_name_hint) ^ world_seed) & 0x7fffffff
	var genome := for_archetype(archetype, rng)
	# The founder's seed stamp is the species identity, not an individual's.
	genome.seed_value = int(rng.seed)
	genome.generation = 0
	return genome


## Pull a genome toward an archetype's plan and re-apply the coherence and
## allometry rules. Shared by randomized() and for_archetype().
static func _apply_archetype(genome: CritterGenome, archetype: StringName,
		rng: RandomNumberGenerator) -> void:
	var plans := _archetypes()
	var chosen: Dictionary = plans.get(archetype, plans[&"grazer"])
	var targets: Dictionary = chosen["genes"]
	for gene in targets:
		if gene == GENE_LEG_PAIRS or gene == GENE_HAS_WINGS \
				or gene == GENE_HAS_FINS:
			genome.genes[gene] = clamp_gene(gene, float(targets[gene]))
		else:
			var current: float = float(genome.genes[gene])
			genome.genes[gene] = clamp_gene(gene, lerpf(current, float(targets[gene]), 0.65))

	genome.genes[GENE_EYE_COUNT] = float(2 * (1 + (rng.randi() % 2)))  # 2 or 4
	genome.genes[GENE_TAIL_SEGMENTS] = float(rng.randi_range(0, 6))

	# Coherence: flyers trade leg investment for wings.
	if genome.genes[GENE_HAS_WINGS] >= 0.5:
		genome.genes[GENE_LEG_LENGTH] = clamp_gene(GENE_LEG_LENGTH,
			float(genome.genes[GENE_LEG_LENGTH]) * 0.65)
		genome.genes[GENE_WING_SPAN] = clamp_gene(GENE_WING_SPAN,
			float(genome.genes[GENE_WING_SPAN]) * 1.15)
	# Coherence: a body commits to one medium. Both sets at once is not a
	# flying fish, it is a shape with two propulsion systems and no plan;
	# whichever is better developed wins.
	if genome.genes[GENE_HAS_WINGS] >= 0.5 and genome.genes[GENE_HAS_FINS] >= 0.5:
		if float(genome.genes[GENE_WING_SPAN]) >= float(genome.genes[GENE_FIN_SPAN]):
			genome.genes[GENE_HAS_FINS] = 0.0
		else:
			genome.genes[GENE_HAS_WINGS] = 0.0
	# Coherence: a swimmer streamlines. Legs go, the spine drives.
	if genome.genes[GENE_HAS_FINS] >= 0.5:
		genome.genes[GENE_LEG_PAIRS] = 0.0
		genome.genes[GENE_SPINE_WAVE] = clamp_gene(GENE_SPINE_WAVE,
			maxf(float(genome.genes[GENE_SPINE_WAVE]), 0.18))
		genome.genes[GENE_FIN_SPAN] = clamp_gene(GENE_FIN_SPAN,
			float(genome.genes[GENE_FIN_SPAN]) * 1.1)
	# Coherence: legless builds are longer and more snake-like.
	if genome.genes[GENE_LEG_PAIRS] < 0.5:
		genome.genes[GENE_COUNT_BODY_SEGMENTS] = clamp_gene(GENE_COUNT_BODY_SEGMENTS,
			float(genome.genes[GENE_COUNT_BODY_SEGMENTS]) + 1.0)
		genome.genes[GENE_SPINE_WAVE] = clamp_gene(GENE_SPINE_WAVE,
			float(genome.genes[GENE_SPINE_WAVE]) * 1.6 + 0.05)
	# Allometry: a heavy body needs supports to match — girth and feet get
	# mass-scaled floors so selection can't evolve a boulder on toothpicks
	# that still reads as broken instead of merely funny.
	var mass := genome.body_mass()
	genome.genes[GENE_LEG_GIRTH] = clamp_gene(GENE_LEG_GIRTH,
		maxf(float(genome.genes[GENE_LEG_GIRTH]), sqrt(mass) * 0.34))
	genome.genes[GENE_FOOT_SIZE] = clamp_gene(GENE_FOOT_SIZE,
		maxf(float(genome.genes[GENE_FOOT_SIZE]), sqrt(mass) * 0.10))


## Copy with a new seed stamp (mutations build on a copy).
func cloned(rng: RandomNumberGenerator) -> CritterGenome:
	var child := CritterGenome.new(self)
	if rng != null:
		child.seed_value = rng.randi()
	return child


# ── Evolution operators ────────────────────────────────────────────────────────


## In-place gaussian drift on proportions/angles, ±1 steps on counts, rare
## flips on pattern/wing/fin genes. rate scales both probability and magnitude.
##
## `allow_medium_change` gates the two genes that decide what an animal moves
## through. Breeding leaves it on, so a lineage CAN evolve into the water or
## the air over generations. Spawn-time variation turns it off, because that
## variation is meant to make individuals of a species differ, not to make
## them different animals: measured with it on, a freshly populated world had
## deer with fins standing in the sea and a jellyfish with legs on a beach,
## 16 animals on the wrong side of the water line before anything had bred.
func mutate(rng: RandomNumberGenerator, rate: float = 1.0,
		allow_medium_change: bool = true) -> void:
	var int_genes := _int_genes()
	for gene in genes.keys():
		var current: float = float(genes[gene])
		if gene in int_genes:
			if gene == GENE_HAS_WINGS or gene == GENE_HAS_FINS:
				# Rare gain/loss of wings or fins — the largest jump a body
				# plan can make, and the one that changes its medium.
				if allow_medium_change and rng.randf() < 0.04 * rate:
					genes[gene] = 1.0 - current
				continue
			if gene == GENE_PATTERN or gene == GENE_GAIT_PATTERN:
				# Re-roll coat / gait choice occasionally.
				if rng.randf() < 0.08 * rate:
					var pr := gene_range(gene)
					genes[gene] = float(rng.randi_range(int(pr.x), int(pr.y)))
				continue
			if rng.randf() < 0.15 * rate:
				var step := 1.0 if rng.randf() < 0.5 else -1.0
				genes[gene] = clamp_gene(gene, current + step)
			continue
		if rng.randf() < 0.40 * rate:
			var r := gene_range(gene)
			var span := r.y - r.x
			var drifted: float = current + rng.randfn(0.0, span * 0.15 * rate)
			genes[gene] = clamp_gene(gene, drifted)
	_coerce_coherence()


## Sexual recombination: every gene is picked from a parent (counts) or
## blended (numerics), so the child visibly belongs to both.
static func crossover(a: CritterGenome, b: CritterGenome, rng: RandomNumberGenerator) -> CritterGenome:
	var child := CritterGenome.new()
	child.seed_value = rng.randi()
	child.generation = maxi(a.generation, b.generation) + 1
	var int_genes := _int_genes()
	for gene in a.genes.keys():
		if gene in int_genes:
			child.genes[gene] = a.genes[gene] if rng.randf() < 0.5 else b.genes[gene]
		else:
			var blend := 0.5 + rng.randf_range(-0.25, 0.25)
			var mixed: float = lerpf(float(a.genes[gene]), float(b.genes[gene]), blend)
			child.genes[gene] = clamp_gene(gene, mixed)
	child._coerce_coherence()
	return child


## Keep random combinations from fighting themselves visually.
## Keep a mutated body plan physically coherent.
##
## Runs after every mutation and crossover, so the rules here are what stop
## selection from producing shapes that cannot work. Medium exclusivity is the
## important one: mutation flips has_wings and has_fins independently, and an
## animal carrying both would be handed a medium by whichever check ran first.
func _coerce_coherence() -> void:
	if float(genes[GENE_HAS_WINGS]) >= 0.5 and float(genes[GENE_HAS_FINS]) >= 0.5:
		if float(genes[GENE_WING_SPAN]) >= float(genes[GENE_FIN_SPAN]):
			genes[GENE_HAS_FINS] = 0.0
		else:
			genes[GENE_HAS_WINGS] = 0.0
	if float(genes[GENE_HAS_WINGS]) >= 0.5:
		genes[GENE_LEG_LENGTH] = clamp_gene(GENE_LEG_LENGTH, float(genes[GENE_LEG_LENGTH]) * 0.8)
	if float(genes[GENE_HAS_FINS]) >= 0.5:
		genes[GENE_LEG_PAIRS] = 0.0
		genes[GENE_SPINE_WAVE] = clamp_gene(GENE_SPINE_WAVE,
			maxf(float(genes[GENE_SPINE_WAVE]), 0.18))
	if float(genes[GENE_LEG_PAIRS]) < 0.5:
		genes[GENE_SPINE_WAVE] = clamp_gene(GENE_SPINE_WAVE, float(genes[GENE_SPINE_WAVE]) * 1.2)


# ── Typed readers ──────────────────────────────────────────────────────────────

func segment_count() -> int:
	return clampi(int(round(float(genes[GENE_COUNT_BODY_SEGMENTS]))), 2, 7)


func eye_count() -> int:
	return clampi(int(round(float(genes[GENE_EYE_COUNT]))), 2, 4)


func leg_pairs() -> int:
	return clampi(int(round(float(genes[GENE_LEG_PAIRS]))), 0, 2)


func tail_segment_count() -> int:
	return clampi(int(round(float(genes[GENE_TAIL_SEGMENTS]))), 0, 6)


func has_wings() -> bool:
	return float(genes[GENE_HAS_WINGS]) >= 0.5


func coat_pattern() -> int:
	return clampi(int(round(float(genes[GENE_PATTERN]))), 0, 2)


func gait_pattern() -> int:
	return clampi(int(round(float(genes[GENE_GAIT_PATTERN]))), 0, 3)


func gait_name() -> String:
	match gait_pattern():
		GaitPattern.TROT:
			return "trot"
		GaitPattern.PACE:
			return "pace"
		GaitPattern.BOUND:
			return "bound"
		_:
			return "walk"


# ── Derived stats — the evolution bridge ───────────────────────────────────────
## Morphology drives fitness. These getters are what FaunaSystem will plug
## into move_speed / health / flee multipliers in phase 2, making body genes
## subject to natural selection instead of cosmetic.


## Rough torso volume proxy in arbitrary units (≈ 0.3 – 3.5).
func body_mass() -> float:
	var girth := float(genes[GENE_SEG_GIRTH])
	var length := float(genes[GENE_SEG_LENGTH]) * float(segment_count())
	var mass := girth * girth * length * 1.2
	mass += float(genes[GENE_HEAD_SIZE]) * 0.25
	mass += float(genes[GENE_TAIL_LENGTH]) * float(tail_segment_count()) * 0.05
	return mass


## Land/fly movement speed in world units per second (≈ 1 – 8).
func derived_speed() -> float:
	var speed := 0.0
	if leg_pairs() > 0:
		var pair_factor := 1.0 + float(leg_pairs() - 1) * 0.15
		var leg_power: float = float(genes[GENE_LEG_LENGTH]) * 1.6
		leg_power += float(genes[GENE_STRIDE_AMP]) * 0.8
		leg_power += float(genes[GENE_GAIT_CYCLE]) * 0.6
		speed = 1.0 + pair_factor * leg_power - body_mass() * 0.25
	if has_wings():
		speed = maxf(speed, 1.0) * 0.6 + float(genes[GENE_WING_SPAN]) * 1.1
	if has_fins():
		# A swimmer is driven by its spine and fins. Legless bodies scored
		# almost zero on the leg term above, so without this every fish came
		# out at the 0.4 floor and a shoal barely moved.
		var thrust: float = float(genes.get(GENE_FIN_SPAN, 1.0)) * 1.3
		thrust += float(genes[GENE_SPINE_WAVE]) * 4.0
		thrust += float(genes[GENE_GAIT_CYCLE]) * 0.5
		speed = 1.0 + thrust - body_mass() * 0.15
	return clampf(speed, 0.4, 8.0)


func has_fins() -> bool:
	return float(genes.get(GENE_HAS_FINS, 0.0)) >= 0.5


## Which medium this body is built for. The single place the answer lives, so
## spawning, breeding and the grounding pass cannot disagree about it.
func medium_name() -> StringName:
	if has_fins():
		return &"water"
	if has_wings():
		return &"air"
	return &"land"


## Metres a swimmer holds above the seafloor.
##
## Bigger bodies cruise higher: a whale that hugged the bottom the way a
## goby does would be half buried in it. Scales with mass and fin span, both
## of which are heritable, so a lineage that evolves larger also evolves off
## the bottom.
func derived_swim_height() -> float:
	var height := 0.35 + body_mass() * 0.9
	height += float(genes.get(GENE_FIN_SPAN, 1.0)) * 0.4
	return clampf(height, 0.3, 6.0)


## Metres a flier holds above the ground when cruising.
##
## Wing span lifts, mass pulls down. This is why a bat and an albatross with
## the same wings do not fly at the same height, and it is derived rather than
## authored so a lineage that evolves broader wings genuinely climbs higher.
func derived_cruise_height() -> float:
	var lift := float(genes.get(GENE_WING_SPAN, 1.0)) * 3.4
	var height := 1.2 + lift - body_mass() * 1.1
	return clampf(height, 1.0, 14.0)


## Metres per second of climb and descent. A light body with big wings gets
## off the ground fast; a heavy one labours.
func derived_climb_rate() -> float:
	var rate := float(genes.get(GENE_WING_SPAN, 1.0)) * 1.5
	rate += float(genes.get(GENE_WING_FLAP, 0.5)) * 1.2
	return clampf(rate / maxf(body_mass(), 0.2), 0.6, 6.0)


## Seconds this body can stay airborne before it has to come down.
## Flap-driven flight is expensive; a broad wing that glides lasts longer.
func derived_flight_endurance() -> float:
	var endurance := 5.0 + float(genes.get(GENE_WING_SPAN, 1.0)) * 9.0
	endurance -= float(genes.get(GENE_WING_FLAP, 0.5)) * 4.0
	return clampf(endurance / maxf(body_mass(), 0.25), 4.0, 45.0)


## Toughness scaling with body volume (≈ 3 – 15).
func derived_health() -> float:
	return 3.0 + body_mass() * 3.5


## Escape burst multiplier — jumpy, fast-cycling bodies flee harder.
func derived_flee_multiplier() -> float:
	var burst := 1.2 + float(genes[GENE_STRIDE_AMP]) * 0.6
	burst += float(genes[GENE_GAIT_CYCLE]) * 0.2
	return clampf(burst, 1.1, 2.2)


## Normalized genetic distance to another genome, 0 (identical) to 1.
##
## Each gene contributes its absolute difference divided by its own legal
## range, so a gene that spans 0.05-0.16 counts as much as one that spans
## 2-7. Without that normalization the count genes would drown out every
## proportion and angle in the body, and "distance" would only measure how
## many legs two animals disagree about.
##
## This is the measure speciation is judged on: lineages that drift past a
## threshold from their founder stop being the same animal.
func distance_to(other: CritterGenome) -> float:
	if other == null:
		return 1.0
	var total := 0.0
	var counted := 0
	for gene in genes.keys():
		if not other.genes.has(gene):
			continue
		var r := gene_range(gene)
		var span := maxf(r.y - r.x, 0.0001)
		total += absf(float(genes[gene]) - float(other.genes[gene])) / span
		counted += 1
	return total / float(maxi(counted, 1))


# ── Identity & serialization ───────────────────────────────────────────────────


## Deterministic pseudo-latin species name from the genome seed.
func species_name() -> String:
	var heads := ["bo", "kra", "velu", "mira", "tho", "zuni", "pala", "goro", "nesi", "rulo", "femba", "chi"]
	var mids := ["lo", "ra", "ne", "du", "ki", "sa", "mo", "va"]
	var tails := ["don", "saur", "pod", "lynx", "mite", "wing", "back", "hoof"]
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(seed_value) & 0x7fffffff
	var name: String = heads[rng.randi() % heads.size()]
	if rng.randf() < 0.55:
		name += mids[rng.randi() % mids.size()]
	name += tails[rng.randi() % tails.size()]
	return name.capitalize()


func to_dict() -> Dictionary:
	return {
		"seed": seed_value,
		"generation": generation,
		"genes": genes.duplicate(),
	}


static func from_dict(data: Dictionary) -> CritterGenome:
	var genome := CritterGenome.new()
	genome.seed_value = int(data.get("seed", 0))
	genome.generation = int(data.get("generation", 0))
	var source: Dictionary = data.get("genes", {})
	for gene in _ranges().keys():
		if source.has(gene):
			genome.genes[gene] = clamp_gene(gene, float(source[gene]))
	return genome


## Compact multi-line summary for the Body Lab HUD.
func summary() -> String:
	var lines: PackedStringArray = []
	lines.append("%s  gen %d  %s  [%s]" % [species_name(), generation,
		gait_name(), str(medium_name())])
	lines.append("body: %d segs, mass %.2f" % [segment_count(), body_mass()])
	lines.append("legs: %d pairs, len %.2f, knee %.2f rad, splay %.2f rad" % [
		leg_pairs(), float(genes[GENE_LEG_LENGTH]),
		float(genes[GENE_KNEE_BEND]), float(genes[GENE_STANCE_SPLAY])])
	if has_wings():
		lines.append("wings: span %.2f, flap %.2f rad -> cruise %.1f m, climb %.1f m/s, %.0f s aloft" % [
			float(genes[GENE_WING_SPAN]), float(genes[GENE_WING_FLAP]),
			derived_cruise_height(), derived_climb_rate(),
			derived_flight_endurance()])
	if has_fins():
		lines.append("fins: span %.2f -> swims %.1f m off the bottom" % [
			float(genes[GENE_FIN_SPAN]), derived_swim_height()])
	lines.append("gait: cycle %.2f Hz, stride %.2f rad, wave %.2f rad" % [
		float(genes[GENE_GAIT_CYCLE]), float(genes[GENE_STRIDE_AMP]),
		float(genes[GENE_SPINE_WAVE])])
	lines.append("stats: speed %.2f, hp %.1f, flee x%.2f" % [
		derived_speed(), derived_health(), derived_flee_multiplier()])
	return "\n".join(lines)
