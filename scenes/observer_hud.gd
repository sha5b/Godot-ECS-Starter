class_name ObserverHUD
extends Control

## Observer mode: click any ECS entity (critter, berry bush, campfire) to
## watch its simulation state live — drives, committed action, elements,
## processing tier, health. A pure read-only view over the ECS data layer;
## nothing here feeds back into the simulation.
##
## Left click: select the nearest entity under the cursor
## Esc: clear the selection
## O: toggle the observer off/on

## Input actions, bound in Project Settings > Input Map.
const ACTION_TOGGLE := &"debug_observer_toggle"
const ACTION_SELECT := &"world_select"

const PANEL_WIDTH := 320.0
const PICK_RADIUS_PX := 30.0
const RING_COLOR := Color(0.42, 0.86, 1.0, 0.92)
const REFRESH_INTERVAL := 0.1

var _panel: PanelContainer
var _title: Label
var _body: Label
var _ring: MeshInstance3D

var _selected := -1
var _ecs: EcsSystem
var _refresh_accum := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_panel()


func _exit_tree() -> void:
	if _ring != null and is_instance_valid(_ring):
		_ring.queue_free()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(ACTION_TOGGLE):
		visible = not visible
		if not visible and _ring != null and is_instance_valid(_ring):
			_ring.visible = false
		get_viewport().set_input_as_handled()
		return
	if not visible:
		return
	if event.is_action_pressed(ACTION_SELECT) and event is InputEventMouseButton:
		var picked := _pick_at((event as InputEventMouseButton).position)
		if picked >= 0:
			_select(picked)
		else:
			_deselect()
	elif event.is_action_pressed(&"ui_cancel") and _selected >= 0:
		_deselect()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not visible or _selected < 0:
		return
	var ecs := _find_ecs()
	if ecs == null or not ecs.world.is_alive(_selected):
		_deselect()
		return
	var transform := ecs.world.get_component(_selected, &"CTransform") as CTransform
	if transform != null and _ring != null and is_instance_valid(_ring):
		_ring.visible = true
		_ring.global_position = transform.position + Vector3.UP * 0.12
		_ring.rotate_y(delta * 1.6)
	_refresh_accum += delta
	if _refresh_accum >= REFRESH_INTERVAL:
		_refresh_accum = 0.0
		_refresh_panel()


# ── Picking ──────────────────────────────────────────────────────────────────


## Screen-space pick over the bound EntityView nodes. Views carry no physics
## bodies, so proximity in pixels (with depth as tie-break) is the honest pick.
func _pick_at(mouse: Vector2) -> int:
	var ecs := _find_ecs()
	var camera := get_viewport().get_camera_3d()
	if ecs == null or camera == null:
		return -1
	var dists := PackedFloat32Array()
	var depths := PackedFloat32Array()
	var entities := PackedInt64Array()
	for child in ecs.get_children():
		var view := child as EntityView
		if view == null or not ecs.world.is_alive(view.entity):
			continue
		if camera.is_position_behind(view.global_position):
			continue
		var screen := camera.unproject_position(view.global_position)
		dists.append(mouse.distance_to(screen))
		depths.append(camera.global_position.distance_to(view.global_position))
		entities.append(view.entity)
	var idx := pick_index(dists, depths, PICK_RADIUS_PX)
	return entities[idx] if idx >= 0 else -1


func _find_ecs() -> EcsSystem:
	if _ecs != null and is_instance_valid(_ecs) and _ecs.world != null:
		return _ecs
	for node in get_tree().get_nodes_in_group(&"ecs_systems"):
		if node is EcsSystem:
			_ecs = node
			return _ecs
	return null


# ── Selection ────────────────────────────────────────────────────────────────


func _select(entity: int) -> void:
	_selected = entity
	_panel.visible = true
	var ecs := _find_ecs()
	if ecs != null:
		_ensure_ring(ecs)
	_refresh_panel()


func _deselect() -> void:
	_selected = -1
	if _panel != null:
		_panel.visible = false
	if _ring != null and is_instance_valid(_ring):
		_ring.visible = false


func _refresh_panel() -> void:
	var ecs := _find_ecs()
	if ecs == null:
		return
	var report := build_report(ecs.world, _selected)
	_title.text = "%s  #%d" % [str(report["kind"]).capitalize(), int(report["entity"])]
	_title.add_theme_color_override("font_color", kind_color(report["kind"]))
	_body.text = format_report(report)


## Flat glowing ring on the ground under the selected entity.
func _ensure_ring(ecs: EcsSystem) -> void:
	if _ring != null and is_instance_valid(_ring):
		return
	var ring := MeshInstance3D.new()
	ring.name = "ObserverRing"
	var torus := TorusMesh.new()
	torus.inner_radius = 0.55
	torus.outer_radius = 0.7
	ring.mesh = torus
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = RING_COLOR
	ring.material_override = material
	ring.visible = false
	var host := ecs.get_parent() if ecs.get_parent() != null else ecs
	host.add_child(ring)
	_ring = ring


# ── UI ───────────────────────────────────────────────────────────────────────


func _build_panel() -> void:
	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.offset_left = -PANEL_WIDTH - 14.0
	_panel.offset_right = -14.0
	_panel.offset_top = 56.0
	_panel.offset_bottom = 56.0
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.09, 0.15, 0.86)
	style.border_color = Color(0.32, 0.55, 0.75, 0.65)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 10.0
	style.content_margin_bottom = 10.0
	_panel.add_theme_stylebox_override("panel", style)

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 6)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 15)
	_title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_title.add_theme_constant_override("shadow_offset_x", 1)
	_title.add_theme_constant_override("shadow_offset_y", 1)

	_body = Label.new()
	_body.add_theme_font_size_override("font_size", 13)
	_body.add_theme_color_override("font_color", Color(0.81, 0.85, 0.92))
	_body.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_body.add_theme_constant_override("shadow_offset_x", 1)
	_body.add_theme_constant_override("shadow_offset_y", 1)

	var hint := Label.new()
	hint.text = "click: select · esc: clear · O: hide"
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color(0.56, 0.64, 0.78))

	box.add_child(_title)
	box.add_child(_body)
	box.add_child(hint)
	_panel.add_child(box)
	add_child(_panel)
	_panel.visible = false


# ── Pure data layer (headless-testable) ──────────────────────────────────────


## Nearest-pick over parallel screen-distance/depth arrays.
## Returns the index of the closest entry within `max_dist_px` pixels
## (ties break toward the smaller depth), or -1 when nothing is in range.
static func pick_index(screen_dists: PackedFloat32Array,
		depths: PackedFloat32Array, max_dist_px: float) -> int:
	var best := -1
	var best_dist := max_dist_px
	var best_depth := INF
	for i in screen_dists.size():
		var dist: float = screen_dists[i]
		if dist > best_dist:
			continue
		var depth: float = depths[i]
		if dist < best_dist - 0.001 \
				or (absf(dist - best_dist) <= 0.001 and depth < best_depth):
			best = i
			best_dist = dist
			best_depth = depth
	return best


## Human kind for an entity, inferred from its component signature.
static func kind_of(world: EcsWorld, entity: int) -> StringName:
	if world.has_component(entity, &"CAgent"):
		return &"critter"
	var elemental := world.get_component(entity, &"CElemental") as CElemental
	if elemental != null and elemental.constant_elements.has(ChemistryDefs.Element.FIRE):
		return &"campfire"
	if world.has_component(entity, &"CFood"):
		return &"berry bush"
	var body := world.get_component(entity, &"CBody") as CBody
	if body != null and body.material == CBody.SurfaceMaterial.GRASS:
		return &"grass"
	return &"entity"


## Snapshot of everything the observer can display for one entity.
## Reads components only, so it runs headless and is unit-testable.
static func build_report(world: EcsWorld, entity: int) -> Dictionary:
	var report := {
		"kind": &"entity",
		"entity": entity,
		"generation": entity >> 32,
		"alive": false,
		"tier": -1,
		"tier_note": "",
	}
	if world == null or not world.is_alive(entity):
		return report
	report["alive"] = true
	report["kind"] = kind_of(world, entity)
	var tier := world.tier_of(entity)
	report["tier"] = tier
	report["tier_note"] = tier_note(tier)

	var transform := world.get_component(entity, &"CTransform") as CTransform
	if transform != null:
		report["position"] = transform.position
		report["facing_deg"] = rad_to_deg(transform.facing)
	var velocity := world.get_component(entity, &"CVelocity") as CVelocity
	if velocity != null:
		report["speed"] = velocity.linear.length()
	var health := world.get_component(entity, &"CHealth") as CHealth
	if health != null:
		report["hp"] = health.hp
		report["max_hp"] = health.max_hp
	var agent := world.get_component(entity, &"CAgent") as CAgent
	if agent != null:
		report["action"] = agent.current_action
		report["action_score"] = agent.action_score
		report["action_time"] = agent.action_time
		report["hunger"] = agent.hunger
		report["energy"] = agent.energy
		report["move_speed"] = agent.move_speed
		report["target_entity"] = agent.target_entity
	var elemental := world.get_component(entity, &"CElemental") as CElemental
	if elemental != null:
		report["wetness"] = elemental.wetness
		report["burning"] = elemental.burning
		report["frozen"] = elemental.frozen
		report["charred"] = elemental.charred
		report["elements"] = element_lines(elemental.elements)
		report["sources"] = element_lines(elemental.constant_elements)
	var body := world.get_component(entity, &"CBody") as CBody
	if body != null:
		report["material"] = CBody.SurfaceMaterial.keys()[body.material]
		report["fuel"] = body.fuel
		report["mass"] = body.mass
	var food := world.get_component(entity, &"CFood") as CFood
	if food != null:
		report["nutrition"] = food.nutrition
	var lifetime := world.get_component(entity, &"CLifetime") as CLifetime
	if lifetime != null:
		report["lifetime"] = lifetime.remaining
	var species := world.get_component(entity, &"CSpecies") as CSpecies
	if species != null:
		report["species"] = species.species_id
		report["species_generation"] = species.generation
		report["species_drift"] = species.drift
	var genome := world.get_component(entity, &"CGenome") as CGenome
	if genome != null and genome.genome != null:
		report["lineage"] = genome.species
		report["genome_generation"] = genome.genome.generation
		report["body"] = "%d segs, %d leg pairs, %s" % [
			genome.genome.segment_count(), genome.genome.leg_pairs(),
			genome.genome.gait_name()]
	return report


## Panel text for a report from build_report().
static func format_report(report: Dictionary) -> String:
	if not bool(report.get("alive", false)):
		return "despawned"
	var text := ""
	if report.has("species"):
		# Species first: it is the one line that says what this animal IS.
		text += "%s  gen %d  drift %.0f%%\n" % [
			str(report["species"]), int(report.get("species_generation", 0)),
			float(report.get("species_drift", 0.0)) * 100.0]
	if report.has("body"):
		text += "%s\n" % str(report["body"])
	text += "tier %d — %s\n" % [int(report["tier"]), str(report["tier_note"])]
	if report.has("position"):
		var pos: Vector3 = report["position"]
		text += "pos (%.1f, %.1f, %.1f)  facing %.0f°\n" % [
			pos.x, pos.y, pos.z, float(report.get("facing_deg", 0.0))]
	if report.has("hp"):
		var max_hp := maxf(float(report["max_hp"]), 0.001)
		text += "hp %s %.1f / %.1f\n" % [
			bar(float(report["hp"]) / max_hp), float(report["hp"]), max_hp]
	if report.has("action"):
		text += "action %s  (score %.2f, %.1fs)\n" % [
			str(report["action"]), float(report.get("action_score", 0.0)),
			float(report.get("action_time", 0.0))]
		text += "hunger %s %.2f\n" % [
			bar(float(report.get("hunger", 0.0))), float(report.get("hunger", 0.0))]
		text += "energy %s %.2f\n" % [
			bar(float(report.get("energy", 1.0))), float(report.get("energy", 1.0))]
		var target := int(report.get("target_entity", 0))
		if target > 0:
			text += "target #%d\n" % target
	if report.has("speed"):
		text += "speed %.1f m/s (max %.1f)\n" % [
			float(report["speed"]), float(report.get("move_speed", 0.0))]
	if report.has("material"):
		text += "body %s  fuel %.1fs  mass %.1f\n" % [
			str(report["material"]), float(report.get("fuel", 0.0)),
			float(report.get("mass", 1.0))]
	if report.has("wetness"):
		var flags := ""
		if bool(report["burning"]):
			flags += " burning"
		if bool(report["frozen"]):
			flags += " frozen"
		if bool(report["charred"]):
			flags += " charred"
		if flags == "":
			flags = " —"
		text += "wet %s %.0f%%%s\n" % [
			bar(float(report["wetness"])), float(report["wetness"]) * 100.0, flags]
		if report.has("elements"):
			var elements: Array[String] = report["elements"]
			if not elements.is_empty():
				text += "elements: " + ", ".join(elements) + "\n"
		if report.has("sources"):
			var sources: Array[String] = report["sources"]
			if not sources.is_empty():
				text += "sources: " + ", ".join(sources) + "\n"
	if report.has("nutrition"):
		text += "nutrition %.2f\n" % float(report["nutrition"])
	if report.has("lifetime"):
		text += "lifetime %.1fs\n" % float(report["lifetime"])
	return text.strip_edges(false)


static func tier_note(tier: int) -> String:
	match tier:
		0: return "every frame"
		1: return "every 4th frame"
		2: return "every 12th frame"
		3: return "dormant"
		_: return "?"


static func kind_color(kind: StringName) -> Color:
	match kind:
		&"critter": return Color(1.0, 0.82, 0.4)
		&"campfire": return Color(1.0, 0.62, 0.26)
		&"berry bush": return Color(0.95, 0.4, 0.5)
		&"grass": return Color(0.55, 0.85, 0.5)
		_: return Color(0.8, 0.86, 0.95)


static func bar(value: float, width := 10) -> String:
	var filled := clampi(roundi(value * width), 0, width)
	return "█".repeat(filled) + "·".repeat(width - filled)


static func element_lines(source: Dictionary) -> Array[String]:
	var lines: Array[String] = []
	for element in source:
		var element_name: String = ChemistryDefs.Element.keys()[element]
		lines.append("%s %.2f" % [element_name, float(source[element])])
	lines.sort()
	return lines
