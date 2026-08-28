class_name BodyLab
extends Node3D

## Body Lab — the test environment for procedural critter bodies.
##
## Runs a real EcsWorld + EcsScheduler with the same production systems
## (MovementSystem, BreedingSystem, ViewSyncSystem), so whatever works here
## deploys into the main world by flipping EcsConfig flags. Open directly
## or press B in the main scene; ESC returns.
##
## Controls:
##   1/2/3  select showcase pedestal        R  randomize selected genome
##   F      cycle body plan (grazer/runner/pouncer/serpent/swimmer/glider)
##   M      mutate selected genome          C  crossover slots 1+2 into 3
##   SPACE  treadmill on/off                G  cycle idle/walk/run
##   TAB    cycle gait pattern gene         E  one selection round
##   P      auto-evolution toggle           H  help               ESC main
##
## Headless smoke mode: run with env BODY_LAB_SMOKE=1 to self-check and
## exit non-zero on failure.

## The authored body plans, in the order F steps through them.
const BODY_PLANS: Array[StringName] = [
	&"grazer", &"runner", &"pouncer", &"serpent", &"swimmer", &"glider",
]

const SHOWCASE_SLOTS := 3
const RUNWAY_POPULATION := 8
const RUNWAY_MIN_Z := -14.0
const RUNWAY_MAX_Z := -6.0
const RUNWAY_HALF_X := 8.0
const PEDESTAL_Y := 0.35

var world: EcsWorld
var scheduler := EcsScheduler.new()
var movement := MovementSystem.new()
var breeding := BreedingSystem.new()
var view_sync := ViewSyncSystem.new()

var _rng := RandomNumberGenerator.new()
var _slot_entities: Array[int] = []
var _slot_views: Array[CritterView] = []
var _slot_labels: Array[Label3D] = []
var _slot_rings: Array[MeshInstance3D] = []
var _selected_slot := 0
var _plan_index := 0
var _gait_levels: PackedFloat32Array = [0.0, 0.5, 1.0]
var _gait_level_index := 1
var _treadmill := true
var _runway_entities: Array[int] = []
var _runway_label: Label3D
var _generation := 0
var _auto_evolve := false
var _auto_timer := 0.0
var _hud_timer := 0.0
var _help_visible := true

var _wander_cache: EcsWorld.QueryCache = null
var _wander_timers: Dictionary = {}

var _help_label: Label
var _status_label: Label
var _genome_label: Label
var _smoke_failed := false


func _ready() -> void:
	if OS.get_environment("BODY_LAB_SMOKE") == "1":
		_rng.seed = 0xC0FFEE
	else:
		_rng.randomize()
	_build_stage()
	_build_world()
	_build_showcase()
	_build_runway()
	_build_hud()
	_select_slot(0)
	print("[BodyLab] ready — press H for help, ESC for the main scene")

	if OS.get_environment("BODY_LAB_SMOKE") == "1":
		await get_tree().create_timer(0.6).timeout
		_run_smoke_checks()
		get_tree().quit(1 if _smoke_failed else 0)


func _process(delta: float) -> void:
	scheduler.tick(world, delta)
	if _auto_evolve:
		_auto_timer += delta
		if _auto_timer >= 5.0:
			_auto_timer = 0.0
			_evolution_round()
	_hud_timer += delta
	if _hud_timer >= 0.25:
		_hud_timer = 0.0
		_refresh_hud()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key := (event as InputEventKey).physical_keycode
	match key:
		KEY_1:
			_select_slot(0)
		KEY_2:
			_select_slot(1)
		KEY_3:
			_select_slot(2)
		KEY_R:
			_set_slot_genome(_selected_slot, CritterGenome.randomized(_rng))
		KEY_F:
			# Step through the body plans directly. R rolls a random one, which
			# reaches the rarer plans only about one time in seven — no way to
			# actually look at a swimmer or a glider on demand.
			_plan_index = (_plan_index + 1) % BODY_PLANS.size()
			_set_slot_genome(_selected_slot,
				CritterGenome.for_archetype(BODY_PLANS[_plan_index], _rng))
		KEY_M:
			var genome := _slot_genome(_selected_slot)
			if genome != null:
				genome.mutate(_rng, 1.0)
				genome.seed_value = _rng.randi()
				_set_slot_genome(_selected_slot, genome)
		KEY_C:
			var a := _slot_genome(0)
			var b := _slot_genome(1)
			if a != null and b != null:
				var child := CritterGenome.crossover(a, b, _rng)
				_set_slot_genome(2, child)
				_select_slot(2)
		KEY_SPACE:
			_treadmill = not _treadmill
			_apply_treadmill()
		KEY_G:
			_gait_level_index = (_gait_level_index + 1) % _gait_levels.size()
			_apply_treadmill()
		KEY_TAB:
			var genome := _slot_genome(_selected_slot)
			if genome != null:
				genome.genes[CritterGenome.GENE_GAIT_PATTERN] = float(
					(genome.gait_pattern() + 1) % 4)
				genome.seed_value = _rng.randi()
				_set_slot_genome(_selected_slot, genome)
		KEY_E:
			_evolution_round()
		KEY_P:
			_auto_evolve = not _auto_evolve
			_auto_timer = 0.0
		KEY_H:
			_help_visible = not _help_visible
			_help_label.visible = _help_visible
		KEY_ESCAPE:
			get_tree().change_scene_to_file("res://scenes/main.tscn")


# ── World assembly — production systems, lab population ──────────────────────

func _build_world() -> void:
	world = EcsWorld.new()
	world.focus_position = Vector3(0.0, 0.0, -4.0)
	movement.bounds_radius = 22.0
	breeding.partner_radius = 4.0
	breeding.breed_cooldown = 14.0
	breeding.max_population = RUNWAY_POPULATION + 8
	breeding.maturity_delay = 4.0
	scheduler.register(&"movement", movement.tick, EcsScheduler.Phase.SIM, 20)
	scheduler.register(&"breeding", breeding.tick, EcsScheduler.Phase.SIM, 55)
	scheduler.register(&"lab_wander", _wander_tick, EcsScheduler.Phase.SIM, 60)
	scheduler.register(&"view_sync", view_sync.tick, EcsScheduler.Phase.VIEW, 70)


## SIM-phase wander driver: points runway critters at fresh targets so the
## gait speed ratio reflects real movement. Stands in for UtilityAI here.
func _wander_tick(world_arg: EcsWorld, delta: float, _frame: int) -> void:
	if _wander_cache == null:
		_wander_cache = world_arg.query([&"CGenome", &"CVelocity", &"CTransform"])
	var entities := world_arg.all_entities_scratch(_wander_cache)
	for entity in entities:
		var timer := float(_wander_timers.get(entity, 0.0)) - delta
		var transform := world_arg.get_component(entity, &"CTransform") as CTransform
		var velocity := world_arg.get_component(entity, &"CVelocity") as CVelocity
		var agent := world_arg.get_component(entity, &"CAgent") as CAgent
		if transform == null or velocity == null or agent == null:
			continue
		if timer <= 0.0:
			timer = _rng.randf_range(2.0, 4.5)
			var target := Vector3(
				_rng.randf_range(-RUNWAY_HALF_X, RUNWAY_HALF_X),
				transform.position.y,
				_rng.randf_range(RUNWAY_MIN_Z, RUNWAY_MAX_Z))
			var dir := (target - transform.position) * Vector3(1.0, 0.0, 1.0)
			if dir.length_squared() > 0.01:
				dir = dir.normalized()
				velocity.linear = dir * agent.move_speed * 0.6
				transform.facing = atan2(dir.x, dir.z)
		_wander_timers[entity] = timer


# ── Population ────────────────────────────────────────────────────────────────

func _pedestal_position(slot: int) -> Vector3:
	return Vector3((float(slot) - 1.0) * 4.0, PEDESTAL_Y, 0.0)


func _spawn_showcase(slot: int, genome: CritterGenome) -> void:
	while _slot_entities.size() <= slot:
		_slot_entities.append(0)
		_slot_views.append(null)
	var entity: int = _slot_entities[slot]
	var view := _slot_views[slot]
	if entity != 0 and world.is_alive(entity) and view != null:
		world.add_component(entity, CGenome.from_genome(genome))
		return
	var transform := CTransform.new()
	transform.position = _pedestal_position(slot)
	entity = world.spawn()
	world.add_component(entity, transform)
	world.add_component(entity, CGenome.from_genome(genome))
	view = CritterView.new()
	view.position = transform.position
	add_child(view)
	view_sync.bind(entity, view)
	_slot_entities[slot] = entity
	_slot_views[slot] = view
	_apply_treadmill()
	_update_slot_label(slot)


func _slot_genome(slot: int) -> CritterGenome:
	if slot >= _slot_entities.size():
		return null
	var comp := world.get_component(_slot_entities[slot], &"CGenome") as CGenome
	return comp.genome if comp != null else null


func _set_slot_genome(slot: int, genome: CritterGenome) -> void:
	_spawn_showcase(slot, genome)
	_update_slot_label(slot)
	_refresh_genome_panel()


func _spawn_runway(genome: CritterGenome, position: Vector3) -> void:
	var transform := CTransform.new()
	transform.position = position
	transform.facing = _rng.randf() * TAU
	var velocity := CVelocity.new()
	var agent := CAgent.new()
	agent.brain = UtilityBrain.critter_brain()
	var comp := CGenome.from_genome(genome)
	agent.move_speed = comp.derived_move_speed
	var entity := world.spawn()
	world.add_component(entity, transform)
	world.add_component(entity, velocity)
	world.add_component(entity, agent)
	world.add_component(entity, comp)
	var view := CritterView.new()
	view.position = position
	add_child(view)
	view_sync.bind(entity, view)
	_runway_entities.append(entity)


## Artificial selection: keep the fastest half, refill with crossover
## children of the survivors. Bodies visibly drift within a few rounds.
func _evolution_round() -> void:
	_prune_runway()
	if _runway_entities.size() < 2:
		return
	var scored: Array = []
	for entity in _runway_entities:
		var comp := world.get_component(entity, &"CGenome") as CGenome
		if comp == null:
			continue
		var score := comp.derived_move_speed * _rng.randf_range(0.85, 1.15)
		scored.append([score, entity])
	scored.sort_custom(func(a, b): return float(a[0]) > float(b[0]))
	var keep := maxi(scored.size() / 2, 2)
	for i in range(keep, scored.size()):
		world.commands.despawn(int(scored[i][1]))
	world.flush_commands()
	_prune_runway()
	while _runway_entities.size() < RUNWAY_POPULATION and not _runway_entities.is_empty():
		var pa := world.get_component(_runway_entities[_rng.randi() % _runway_entities.size()], &"CGenome") as CGenome
		var pb := world.get_component(_runway_entities[_rng.randi() % _runway_entities.size()], &"CGenome") as CGenome
		var child := CritterGenome.crossover(pa.genome, pb.genome, _rng)
		child.mutate(_rng, 1.0)
		var parent_transform := world.get_component(
			_runway_entities[_rng.randi() % _runway_entities.size()], &"CTransform") as CTransform
		var pos := parent_transform.position if parent_transform != null else Vector3.ZERO
		_spawn_runway(child, pos + Vector3(_rng.randf_range(-1.5, 1.5), 0.0, _rng.randf_range(-1.5, 1.5)))
	_generation += 1
	_update_runway_label()
	_refresh_genome_panel()


func _prune_runway() -> void:
	var alive: Array[int] = []
	for entity in _runway_entities:
		if world.is_alive(entity):
			alive.append(entity)
		else:
			_wander_timers.erase(entity)
	_runway_entities = alive


# ── UI ────────────────────────────────────────────────────────────────────────

func _select_slot(slot: int) -> void:
	_selected_slot = slot
	for i in _slot_rings.size():
		_slot_rings[i].visible = i == slot
	_refresh_genome_panel()


func _apply_treadmill() -> void:
	var level := _gait_levels[_gait_level_index] if _treadmill else 0.0
	for view in _slot_views:
		if view != null:
			view.demo_speed_ratio = level


func _update_slot_label(slot: int) -> void:
	if slot >= _slot_labels.size():
		return
	var genome := _slot_genome(slot)
	if genome == null:
		return
	_slot_labels[slot].text = "%s\ngen %d  spd %.1f" % [
		genome.species_name(), genome.generation, genome.derived_speed()]


func _update_runway_label() -> void:
	_prune_runway()
	var best := 0.0
	var total := 0.0
	for entity in _runway_entities:
		var comp := world.get_component(entity, &"CGenome") as CGenome
		if comp == null:
			continue
		best = maxf(best, comp.derived_move_speed)
		total += comp.derived_move_speed
	var avg := total / maxf(float(_runway_entities.size()), 1.0)
	_runway_label.text = "EVOLUTION RUNWAY\ngen %d   pop %d   best %.2f   avg %.2f" % [
		_generation, _runway_entities.size(), best, avg]


func _refresh_hud() -> void:
	var gait_names := ["idle", "walk", "run"]
	var status := "slot %d   treadmill %s   gait %s   auto-evolve %s" % [
		_selected_slot + 1,
		"on" if _treadmill else "off",
		gait_names[_gait_level_index] if _treadmill else "idle",
		"on" if _auto_evolve else "off"]
	_status_label.text = status
	_update_runway_label()


func _refresh_genome_panel() -> void:
	var genome := _slot_genome(_selected_slot)
	_genome_label.text = genome.summary() if genome != null else ""


# ── Stage construction ────────────────────────────────────────────────────────

func _build_stage() -> void:
	var camera := Camera3D.new()
	camera.position = Vector3(0.0, 10.5, 9.0)
	add_child(camera)
	camera.look_at(Vector3(0.0, 0.4, -3.0), Vector3.UP)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, -32.0, 0.0)
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	add_child(sun)

	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.13, 0.15, 0.2)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.55, 0.6, 0.7)
	environment.ambient_light_energy = 0.7
	var world_env := WorldEnvironment.new()
	world_env.environment = environment
	add_child(world_env)

	var floor_mesh := MeshInstance3D.new()
	var floor_box := BoxMesh.new()
	floor_box.size = Vector3(44.0, 0.2, 44.0)
	floor_mesh.mesh = floor_box
	floor_mesh.position = Vector3(0.0, -0.1, -4.0)
	var floor_mat := StandardMaterial3D.new()
	floor_mat.roughness = 1.0
	floor_mat.albedo_color = Color(0.2, 0.22, 0.27)
	floor_mesh.material_override = floor_mat
	add_child(floor_mesh)

	# Pedestals + selection rings.
	var pedestal_mat := StandardMaterial3D.new()
	pedestal_mat.roughness = 1.0
	pedestal_mat.albedo_color = Color(0.3, 0.33, 0.4)
	var ring_mat := StandardMaterial3D.new()
	ring_mat.albedo_color = Color(0.3, 0.9, 0.5)
	ring_mat.emission_enabled = true
	ring_mat.emission = Color(0.2, 0.8, 0.4)
	for slot in SHOWCASE_SLOTS:
		var pedestal := MeshInstance3D.new()
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = 1.1
		cylinder.bottom_radius = 1.25
		cylinder.height = PEDESTAL_Y
		pedestal.mesh = cylinder
		pedestal.material_override = pedestal_mat
		pedestal.position = Vector3((float(slot) - 1.0) * 4.0, PEDESTAL_Y * 0.5, 0.0)
		add_child(pedestal)

		var ring := MeshInstance3D.new()
		var ring_mesh := CylinderMesh.new()
		ring_mesh.top_radius = 1.35
		ring_mesh.bottom_radius = 1.35
		ring_mesh.height = 0.03
		ring.mesh = ring_mesh
		ring.material_override = ring_mat
		ring.position = Vector3((float(slot) - 1.0) * 4.0, 0.015, 0.0)
		ring.visible = false
		add_child(ring)
		_slot_rings.append(ring)

	# Runway frame.
	var frame_mat := StandardMaterial3D.new()
	frame_mat.roughness = 1.0
	frame_mat.albedo_color = Color(0.28, 0.3, 0.36)
	for side in [-1.0, 1.0]:
		var rail := MeshInstance3D.new()
		var rail_box := BoxMesh.new()
		rail_box.size = Vector3(0.15, 0.1, RUNWAY_MAX_Z - RUNWAY_MIN_Z + 1.0)
		rail.mesh = rail_box
		rail.material_override = frame_mat
		rail.position = Vector3(side * (RUNWAY_HALF_X + 0.4), 0.05, (RUNWAY_MIN_Z + RUNWAY_MAX_Z) * 0.5)
		add_child(rail)

	_runway_label = Label3D.new()
	_runway_label.text = "EVOLUTION RUNWAY"
	_runway_label.position = Vector3(0.0, 2.6, (RUNWAY_MIN_Z + RUNWAY_MAX_Z) * 0.5)
	_runway_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_runway_label.font_size = 64
	_runway_label.outline_size = 8
	add_child(_runway_label)


func _build_showcase() -> void:
	for slot in SHOWCASE_SLOTS:
		_spawn_showcase(slot, CritterGenome.randomized(_rng))
		var label := Label3D.new()
		label.position = _pedestal_position(slot) + Vector3(0.0, 1.9, 0.0)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.font_size = 48
		label.outline_size = 6
		add_child(label)
		_slot_labels.append(label)
		_update_slot_label(slot)


func _build_runway() -> void:
	for i in RUNWAY_POPULATION:
		var position := Vector3(
			_rng.randf_range(-RUNWAY_HALF_X + 1.0, RUNWAY_HALF_X - 1.0),
			0.0,
			_rng.randf_range(RUNWAY_MIN_Z + 1.0, RUNWAY_MAX_Z - 1.0))
		_spawn_runway(CritterGenome.randomized(_rng), position)
	_update_runway_label()


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	_help_label = Label.new()
	_help_label.position = Vector2(12, 12)
	_help_label.add_theme_font_size_override("font_size", 15)
	_help_label.add_theme_color_override("font_color", Color.WHITE)
	_help_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	_help_label.text = "BODY LAB — procedural critters
[1/2/3] select   [R] randomize   [F] body plan   [M] mutate   [C] cross 1+2 → 3
[SPACE] treadmill   [G] idle/walk/run   [TAB] gait pattern
[E] selection round   [P] auto-evolve   [H] help   [ESC] main scene"
	layer.add_child(_help_label)

	_status_label = Label.new()
	_status_label.position = Vector2(12, 118)
	_status_label.add_theme_font_size_override("font_size", 15)
	_status_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.8))
	_status_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	layer.add_child(_status_label)

	_genome_label = Label.new()
	_genome_label.position = Vector2(12, 150)
	_genome_label.add_theme_font_size_override("font_size", 14)
	_genome_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.95))
	_genome_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	layer.add_child(_genome_label)


# ── Headless smoke checks ─────────────────────────────────────────────────────

func _run_smoke_checks() -> void:
	var genome_carriers := world.query([&"CGenome"])
	_smoke("population", genome_carriers.count() == SHOWCASE_SLOTS + RUNWAY_POPULATION)
	_smoke("bindings", view_sync.binding_count() >= SHOWCASE_SLOTS + RUNWAY_POPULATION)
	var before := _slot_genome(0)
	var mutated := CritterGenome.new(before)
	mutated.mutate(_rng, 1.0)
	_smoke("mutation drift", mutated.genes != before.genes)
	var child := CritterGenome.crossover(_slot_genome(0), _slot_genome(1), _rng)
	_smoke("crossover generation", child.generation >= 1)
	_evolution_round()
	_prune_runway()
	_smoke("evolution round", _runway_entities.size() == RUNWAY_POPULATION and _generation == 1)
	print("[BodyLab] smoke %s" % ("FAILED" if _smoke_failed else "passed"))


func _smoke(check: String, ok: bool) -> void:
	if not ok:
		_smoke_failed = true
	print("  [%s] %s" % ["FAIL" if not ok else "PASS", check])
