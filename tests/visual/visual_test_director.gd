extends Node3D

## Visual + automated integration test for the BotW-style ECS runtime.
##
## Runs a scripted scenario against the live simulation:
##   1. FIRE      — campfire ignites the meadow, fire spreads downwind
##   2. PANIC     — critters' utility AI commits to panic and flees
##   3. RAIN      — rain soaks the world and extinguishes the fire
##   4. LIGHTNING — a strike chains through the (now wet, conductive) bodies
##   5. ICE       — the ice shrine freezes soaked bodies around it
##
## In the editor this draws a HUD checklist; headless it prints the
## checklist and exits non-zero on any failure, so it doubles as a CI
## integration test:
##   godot --headless --path . res://tests/visual/ecs_visual_test.tscn
##
## Keys while running visually: R rain, L lightning, F1 restart scenario.

const CHECKS := {
	"fire": "Fire spreads through grass",
	"panic": "Utility AI: critters panic and flee",
	"rain": "Rain extinguishes the fire",
	"lightning": "Lightning chains between conductors",
	"ice": "Ice freezes soaked bodies",
}

const CRITTER_TINTS: Array[Color] = [
	Color(0.9, 0.75, 0.5), Color(0.6, 0.8, 0.9), Color(0.85, 0.6, 0.7),
	Color(0.7, 0.85, 0.6), Color(0.95, 0.9, 0.6), Color(0.65, 0.65, 0.95),
	Color(0.9, 0.6, 0.4), Color(0.55, 0.9, 0.8),
]

var ecs: EcsSystem
var grass_field: Node
var fx: Node3D
var headless := false

var phase := &"boot"
var phase_time := 0.0
var scenario_time := 0.0
var checks_passed := 0
var checks_failed := 0

var _campfire_entity := 0
var _crate_entities: Array[int] = []
var _critter_entities: Array[int] = []
var _elemental_cache: EcsWorld.QueryCache = null
var _agent_cache: EcsWorld.QueryCache = null
var _hud_checks: Dictionary = {}
var _hud_stats: Label
var _hud_title: Label
var _hud_timer := 0.0


func _ready() -> void:
	headless = DisplayServer.get_name() == "headless"
	seed(20260827)  # deterministic scenario for repeatable CI runs
	ecs = $EcsSystem
	grass_field = $GrassField
	fx = $ChemistryFx

	SharedWorld.wind_direction = Vector3(1, 0, 0.2).normalized()
	SharedWorld.wind_strength = 2.5
	SharedWorld.rain_intensity = 0.0

	ecs.add_event_listener(_on_ecs_event)
	ecs.chemistry.debug_profile = true
	grass_field.setup(ecs.world)

	_spawn_meadow()
	_spawn_campfire()
	_spawn_puddle()
	_spawn_ice_shrine()
	_spawn_crates()
	_spawn_critters()
	_spawn_berries()

	if not headless:
		_build_hud()
	_set_phase(&"fire")


func _process(delta: float) -> void:
	phase_time += delta
	scenario_time += delta

	match phase:
		&"fire":
			_run_fire_check()
		&"panic":
			_run_panic_check()
		&"rain":
			_run_rain_check()
		&"lightning":
			_run_lightning_check()
		&"ice":
			_run_ice_check()
		&"done":
			pass

	if not headless and phase != &"done":
		_hud_timer += delta
		if _hud_timer >= 0.25:
			_hud_timer = 0.0
			_update_hud()


# ── Scenario phases ──────────────────────────────────────────────────────────


func _run_fire_check() -> void:
	# The campfire alone must push the fire outward; wind bias drifts it.
	if _count_burning() >= 5 or phase_time > 30.0:
		_record("fire", _count_burning() >= 5)
		_set_phase(&"panic")


func _run_panic_check() -> void:
	if _any_critter_panicking() or phase_time > 12.0:
		_record("panic", _any_critter_panicking())
		SharedWorld.rain_intensity = 1.0
		_set_phase(&"rain")


var _rain_recorded := false


func _run_rain_check() -> void:
	if not _rain_recorded and (_count_burning() == 0 or phase_time > 40.0):
		_rain_recorded = true
		_record("rain", _count_burning() == 0)
	# Soak a little longer so conductivity is high for the strike.
	if _rain_recorded and phase_time > 6.0:
		_set_phase(&"lightning")


func _run_lightning_check() -> void:
	if not _struck_primary and _crate_entities.size() > 0:
		_struck_primary = true
		var crate_pos := (ecs.world.get_component(_crate_entities[0], &"CTransform") as CTransform).position
		ecs.strike(crate_pos, 1.2)
	if phase_time > 1.2 and not _struck_secondary:
		_struck_secondary = true
		if _crate_entities.size() > 1:
			var crate_pos := (ecs.world.get_component(_crate_entities[1], &"CTransform") as CTransform).position
			ecs.strike(crate_pos, 1.2)
	if _lightning_shocks >= 3 or phase_time > 8.0:
		_record("lightning", _lightning_shocks >= 3)
		_set_phase(&"ice")


func _run_ice_check() -> void:
	if _count_frozen() >= 3 or phase_time > 20.0:
		_record("ice", _count_frozen() >= 3)
		_set_phase(&"done")
		_finish_scenario()


func _finish_scenario() -> void:
	var verdict := "SCENARIO PASS (%d/%d)" % [checks_passed, CHECKS.size()]
	if checks_failed > 0:
		verdict = "SCENARIO FAIL (%d failed)" % checks_failed
	print("\n=== Visual ECS test: %s ===" % verdict)
	if headless:
		_print_perf_summary()
		get_tree().quit(0 if checks_failed == 0 else 1)
	elif _hud_title != null:
		_hud_title.text = "BotW-style ECS — %s" % verdict


func _record(check: String, passed: bool) -> void:
	if passed:
		checks_passed += 1
		print("[VisualTest] PASS — %s" % CHECKS[check])
	else:
		checks_failed += 1
		print("[VisualTest] FAIL — %s" % CHECKS[check])
	var label: Label = _hud_checks.get(check)
	if label != null:
		label.text = ("✔ " if passed else "✘ ") + CHECKS[check]
		label.add_theme_color_override("font_color",
			Color(0.5, 1.0, 0.5) if passed else Color(1.0, 0.45, 0.4))


func _set_phase(next: StringName) -> void:
	phase = next
	phase_time = 0.0
	print("[VisualTest] phase -> %s at t=%.1f" % [String(next), scenario_time])


# ── Content spawning ─────────────────────────────────────────────────────────


func _spawn_meadow() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260827
	var positions: Array[Vector3] = []
	var fuels: Array[float] = []
	for x in range(-24, 25, 2):
		for z in range(-24, 25, 2):
			var pos := Vector3(x + rng.randf_range(-0.7, 0.7), 0.0, z + rng.randf_range(-0.7, 0.7))
			if pos.length() < 4.0:
				continue  # campfire plaza
			if pos.distance_to(Vector3(-16, 0, 10)) < 4.5:
				continue  # puddle
			if pos.distance_to(Vector3(12, 0, 14)) < 2.5:
				continue  # ice shrine (aura must reach surrounding grass)
			positions.append(pos)
			fuels.append(rng.randf_range(1.0, 2.4))
	# One multimesh reservation instead of per-blade reallocation.
	grass_field.reserve(positions.size())
	for i in positions.size():
		grass_field.spawn_blade(positions[i], fuels[i])


func _spawn_campfire() -> void:
	_campfire_entity = ecs.world.spawn()
	var transform := CTransform.new()
	transform.position = Vector3.ZERO
	ecs.world.add_component(_campfire_entity, transform)
	var body := CBody.new()
	body.material = CBody.SurfaceMaterial.STONE
	ecs.world.add_component(_campfire_entity, body)
	var elemental := CElemental.new()
	elemental.constant_elements[ChemistryDefs.Element.FIRE] = 1.0
	ecs.world.add_component(_campfire_entity, elemental)
	ecs.view_sync.bind(_campfire_entity, _make_prop_view(
		Vector3.ZERO, Vector3(1.7, 0.7, 1.7), &"cylinder", Color(0.45, 0.28, 0.16)))
	_attach_campfire_flame(Vector3.ZERO)


func _spawn_puddle() -> void:
	var position := Vector3(-16, 0, 10)
	var entity := ecs.world.spawn()
	var transform := CTransform.new()
	transform.position = position
	ecs.world.add_component(entity, transform)
	var body := CBody.new()
	body.material = CBody.SurfaceMaterial.STONE
	ecs.world.add_component(entity, body)
	var elemental := CElemental.new()
	elemental.constant_elements[ChemistryDefs.Element.WATER] = 1.0
	ecs.world.add_component(entity, elemental)
	ecs.view_sync.bind(entity, _make_prop_view(
		position, Vector3(7.0, 0.12, 7.0), &"cylinder", Color(0.3, 0.55, 0.9)))


func _spawn_ice_shrine() -> void:
	var position := Vector3(12, 0, 14)
	var entity := ecs.world.spawn()
	var transform := CTransform.new()
	transform.position = position
	ecs.world.add_component(entity, transform)
	var body := CBody.new()
	body.material = CBody.SurfaceMaterial.STONE
	ecs.world.add_component(entity, body)
	var elemental := CElemental.new()
	elemental.constant_elements[ChemistryDefs.Element.ICE] = 1.0
	ecs.world.add_component(entity, elemental)
	ecs.view_sync.bind(entity, _make_prop_view(
		position, Vector3(1.2, 2.2, 1.2), &"box", Color(0.7, 0.9, 1.0)))


func _spawn_crates() -> void:
	for i in 5:
		var position := Vector3(16.0 + i * 3.4, 0.0, -10.0 + (i % 2) * 1.2)
		var entity := ecs.world.spawn()
		var transform := CTransform.new()
		transform.position = position
		transform.facing = i * 0.4
		ecs.world.add_component(entity, transform)
		var body := CBody.new()
		body.material = CBody.SurfaceMaterial.METAL
		body.mass = 4.0
		ecs.world.add_component(entity, body)
		var elemental := CElemental.new()
		ecs.world.add_component(entity, elemental)
		var health := CHealth.new()
		health.max_hp = 40.0
		health.hp = 40.0
		ecs.world.add_component(entity, health)
		_crate_entities.append(entity)
		ecs.view_sync.bind(entity, _make_prop_view(
			transform.position, Vector3(1.1, 1.1, 1.1), &"box", Color(0.62, 0.65, 0.72), true))


func _spawn_critters() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in CRITTER_TINTS.size():
		var angle := TAU * i / float(CRITTER_TINTS.size())
		var position := Vector3(cos(angle) * 9.0, 0.0, sin(angle) * 9.0) \
			+ Vector3(rng.randf_range(-2, 2), 0, rng.randf_range(-2, 2))
		var entity := ecs.world.spawn()
		var transform := CTransform.new()
		transform.position = position
		ecs.world.add_component(entity, transform)
		ecs.world.add_component(entity, CVelocity.new())
		var health := CHealth.new()
		health.max_hp = 8.0
		health.hp = 8.0
		ecs.world.add_component(entity, health)
		var body := CBody.new()
		body.material = CBody.SurfaceMaterial.FLESH
		body.fuel = 3.0
		ecs.world.add_component(entity, body)
		ecs.world.add_component(entity, CElemental.new())
		var agent := CAgent.new()
		agent.brain = UtilityBrain.critter_brain()
		agent.move_speed = rng.randf_range(2.4, 3.4)
		agent.hunger = rng.randf_range(0.35, 0.85)
		ecs.world.add_component(entity, agent)
		_critter_entities.append(entity)
		ecs.view_sync.bind(entity, _make_prop_view(
			position, Vector3(0.7, 1.0, 0.7), &"capsule", CRITTER_TINTS[i]))


func _spawn_berries() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	for i in 12:
		var position := Vector3(rng.randf_range(-22, 22), 0.0, rng.randf_range(-22, 22))
		if position.length() < 5.0:
			continue
		var entity := ecs.world.spawn()
		var transform := CTransform.new()
		transform.position = position
		ecs.world.add_component(entity, transform)
		var body := CBody.new()
		body.material = CBody.SurfaceMaterial.GRASS
		body.fuel = 0.6
		ecs.world.add_component(entity, body)
		ecs.world.add_component(entity, CElemental.new())
		var food := CFood.new()
		food.nutrition = 0.55
		ecs.world.add_component(entity, food)
		ecs.view_sync.bind(entity, _make_prop_view(
			position, Vector3(0.5, 0.5, 0.5), &"sphere", Color(0.85, 0.2, 0.3)))


## One prop view node with an EntityView root and a shaped mesh child.
## The mesh child is lifted by half its height so the prop sits ON the ground
## instead of being half-buried in it. `with_collision` adds a static body.
func _make_prop_view(position: Vector3, size: Vector3,
		shape: StringName, tint: Color, with_collision := false) -> EntityView:
	var view := EntityView.new()
	view.position = position
	view.tint = tint
	var mesh := MeshInstance3D.new()
	match shape:
		&"box":
			var box := BoxMesh.new()
			box.size = size
			mesh.mesh = box
		&"sphere":
			var sphere := SphereMesh.new()
			sphere.radius = size.x * 0.5
			sphere.height = size.x
			mesh.mesh = sphere
		&"capsule":
			var capsule := CapsuleMesh.new()
			capsule.radius = size.x * 0.5
			capsule.height = size.y
			mesh.mesh = capsule
		&"cylinder":
			var cylinder := CylinderMesh.new()
			cylinder.top_radius = size.x * 0.5
			cylinder.bottom_radius = size.x * 0.5
			cylinder.height = size.y
			mesh.mesh = cylinder
	mesh.position.y = size.y * 0.5
	view.add_child(mesh)
	if with_collision:
		var body := StaticBody3D.new()
		var collision := CollisionShape3D.new()
		var box_shape := BoxShape3D.new()
		box_shape.size = size
		collision.shape = box_shape
		collision.position.y = size.y * 0.5
		body.add_child(collision)
		view.add_child(body)
	add_child(view)
	return view


## Visible flame for the campfire: emissive cone plus a flickering light.
func _attach_campfire_flame(position: Vector3) -> void:
	var flame := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.1
	cone.bottom_radius = 0.55
	cone.height = 1.1
	flame.mesh = cone
	var material := StandardMaterial3D.new()
	material.emission_enabled = true
	material.emission = Color(1.0, 0.55, 0.15)
	material.emission_energy_multiplier = 2.4
	material.albedo_color = Color(1.0, 0.6, 0.2)
	flame.material_override = material
	flame.position = position + Vector3(0, 1.1, 0)
	add_child(flame)
	var light := OmniLight3D.new()
	light.omni_range = 9.0
	light.light_color = Color(1.0, 0.6, 0.3)
	light.light_energy = 2.2
	light.position = position + Vector3(0, 1.6, 0)
	add_child(light)
	light.set_meta("flicker", true)

# ── Queries for scenario state ───────────────────────────────────────────────


var _ignitions_seen := 0
var _lightning_shocks := 0
var _struck_primary := false
var _struck_secondary := false


func _on_ecs_event(channel: StringName, payload: Dictionary) -> void:
	match channel:
		ChemistryDefs.CHANNEL_IGNITED:
			_ignitions_seen += 1
		ChemistryDefs.CHANNEL_SHOCKED:
			_lightning_shocks += 1
	fx.call("on_ecs_event", channel, payload)
	# Grass recolors are event-driven — forward chemistry state changes.
	grass_field.call("on_ecs_event", channel, payload)


func _count_burning() -> int:
	if _elemental_cache == null:
		_elemental_cache = ecs.world.query([&"CElemental"])
	var burning := 0
	for entity in ecs.world.all_entities(_elemental_cache):
		var elemental := ecs.world.get_component(entity, &"CElemental") as CElemental
		if elemental != null and elemental.burning:
			burning += 1
	return burning


func _count_frozen() -> int:
	if _elemental_cache == null:
		_elemental_cache = ecs.world.query([&"CElemental"])
	var frozen := 0
	for entity in ecs.world.all_entities(_elemental_cache):
		var elemental := ecs.world.get_component(entity, &"CElemental") as CElemental
		if elemental != null and elemental.frozen:
			frozen += 1
	return frozen


func _any_critter_panicking() -> bool:
	if _agent_cache == null:
		_agent_cache = ecs.world.query([&"CAgent"])
	for entity in ecs.world.all_entities(_agent_cache):
		var agent := ecs.world.get_component(entity, &"CAgent") as CAgent
		if agent != null and agent.current_action == &"panic":
			return true
	return false


## Honest CPU numbers for the run: microseconds per system, last tick.
func _print_perf_summary() -> void:
	var times: Dictionary = ecs.scheduler.system_times
	var rows: Array[String] = []
	for system_name in times:
		rows.append("%6d us  %s" % [int(times[system_name]), String(system_name)])
	rows.sort()
	print("[VisualTest] per-system CPU (last tick):\n" + "\n".join(rows))
	var last: Dictionary = ecs.chemistry.profile_last
	var last_rows: Array[String] = []
	for section in last:
		last_rows.append("%9.1f us last  %s" % [float(last[section]), String(section)])
	last_rows.sort()
	print("[VisualTest] chemistry sections (last tick):\n" + "\n".join(last_rows))
	var sections: Dictionary = ecs.chemistry.profile_sections
	var section_rows: Array[String] = []
	for section in sections:
		section_rows.append("%9.1f us total  %s" % [float(sections[section]), String(section)])
	section_rows.sort()
	print("[VisualTest] chemistry sections (whole run):\n" + "\n".join(section_rows))


# ── HUD ──────────────────────────────────────────────────────────────────────


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(12, 12)
	panel.custom_minimum_size = Vector2(440, 0)
	layer.add_child(panel)
	var box := VBoxContainer.new()
	panel.add_child(box)

	_hud_title = Label.new()
	_hud_title.text = "BotW-style ECS — scenario running"
	box.add_child(_hud_title)

	_hud_stats = Label.new()
	box.add_child(_hud_stats)

	for check in CHECKS:
		var label := Label.new()
		label.text = "… " + CHECKS[check]
		label.add_theme_color_override("font_color", Color(0.9, 0.8, 0.4))
		box.add_child(label)
		_hud_checks[check] = label

	var help := Label.new()
	help.text = "WASD pan · wheel zoom · hold RMB rotate · MMB drag · R rain · L lightning · F1 restart"
	help.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	box.add_child(help)


func _update_hud() -> void:
	var stats: Dictionary = SharedWorld.ecs_stats
	var tiers: PackedInt32Array = stats.get("tier_counts", PackedInt32Array())
	_hud_stats.text = "\n".join([
		"phase: %s   t=%.1fs" % [String(phase), scenario_time],
		"entities: %s   burning: %d   frozen: %d   ignitions: %d" % [
			str(stats.get("entities", 0)), _count_burning(), _count_frozen(), _ignitions_seen,
		],
		"tiers T0/T1/T2/T3: %d/%d/%d/%d" % [tiers[0], tiers[1], tiers[2], tiers[3]],
		"rain: %.1f   wind: %.1f" % [SharedWorld.rain_intensity, SharedWorld.wind_strength],
	])


# ── Manual controls (visual mode) ────────────────────────────────────────────


func _unhandled_input(event: InputEvent) -> void:
	if headless or not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	if key.physical_keycode == KEY_R:
		SharedWorld.rain_intensity = 0.0 if SharedWorld.rain_intensity > 0.0 else 1.0
	elif key.physical_keycode == KEY_L:
		var rng := RandomNumberGenerator.new()
		ecs.strike(Vector3(rng.randf_range(-20, 20), 0, rng.randf_range(-20, 20)), 1.1)
	elif key.physical_keycode == KEY_F1:
		get_tree().reload_current_scene()
