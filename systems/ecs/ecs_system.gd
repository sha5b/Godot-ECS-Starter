class_name EcsSystem
extends BaseSystem

## Drop-in ECS runtime host, following the system-scene doctrine.
##
## Owns the EcsWorld and its scheduler, registers the built-in systems in
## BotW-inspired phases:
##
##   EARLY  TierSystem      — assign processing profiles by distance
##   SIM    Movement        — integrate velocity
##   SIM    UtilityAI       — sense / decide / act
##   SIM    ChemistrySystem — elements × materials, propagation
##   SIM    VitalitySystem  — deaths and expired lifetimes
##   VIEW   ViewSync        — mirror data onto scene nodes
##
## Bridges both ways: SharedWorld weather feeds the chemistry environment,
## and ECS events are forwarded to SystemBus as `ecs_event` plus any
## registered event watchers (the visual FX use those).

## Callables invoked (channel, payload) for every published ECS event
## before it is forwarded to SystemBus.
var event_watchers: Array[Callable] = []

var world: EcsWorld
var scheduler := EcsScheduler.new()
var chemistry: ChemistrySystem
var utility_ai := UtilityAISystem.new()
var movement := MovementSystem.new()
var tiers := TierSystem.new()
var vitality := VitalitySystem.new()
var view_sync := ViewSyncSystem.new()

var _config: EcsConfig
var _stat_timer := 0


func _initialize() -> void:
	_config = _find_child_of_type(EcsConfig) as EcsConfig
	if _config == null:
		push_warning("[EcsSystem] No EcsConfig child — using defaults")
		_config = EcsConfig.new()
		add_child(_config)
	if _config.chemistry_rules == null:
		_config.chemistry_rules = ChemistryRules.new()

	world = EcsWorld.new()
	chemistry = ChemistrySystem.new(_config.chemistry_rules)

	tiers.near_distance = _config.tier_near_distance
	tiers.mid_distance = _config.tier_mid_distance
	tiers.far_distance = _config.tier_far_distance
	tiers.recheck_frames = _config.tier_recheck_frames
	movement.bounds_radius = _config.movement_bounds_radius
	utility_ai.sensor_range = _config.ai_sensor_range
	utility_ai.threat_range = _config.ai_threat_range

	scheduler.register(&"tiering", tiers.tick, EcsScheduler.Phase.EARLY, 10)
	if _config.movement_enabled:
		scheduler.register(&"movement", movement.tick, EcsScheduler.Phase.SIM, 20)
	if _config.ai_enabled:
		scheduler.register(&"ai", utility_ai.tick, EcsScheduler.Phase.SIM, 30)
	if _config.chemistry_enabled:
		scheduler.register(&"chemistry", chemistry.tick, EcsScheduler.Phase.SIM, 40)
	if _config.vitality_enabled:
		scheduler.register(&"vitality", vitality.tick, EcsScheduler.Phase.SIM, 50)
	if _config.view_sync_enabled:
		scheduler.register(&"view_sync", view_sync.tick, EcsScheduler.Phase.VIEW, 70)


## Self-tick when placed standalone: under a WorldECS the world root drives
## system_process in priority order, but any other parent means this system
## must run itself (drop-in doctrine).
func _process(delta: float) -> void:
	if not (get_parent() is WorldECS):
		system_process(delta)


func system_process(delta: float) -> void:
	if world == null:
		return

	# Bridge SharedWorld -> ECS environment.
	world.focus_position = SharedWorld.camera_world_pos
	chemistry.env["rain_intensity"] = SharedWorld.rain_intensity
	chemistry.env["wind_direction"] = SharedWorld.wind_direction
	chemistry.env["wind_strength"] = SharedWorld.wind_strength

	scheduler.tick(world, delta)
	_forward_events()

	_stat_timer += 1
	if _stat_timer >= 15:
		_stat_timer = 0
		world.refresh_stats()
		var stats := world.stats.duplicate(true)
		stats["system_times_us"] = scheduler.system_times.duplicate()
		SharedWorld.ecs_stats = stats


## Fire lightning at a world position — the player-facing chemistry hook.
func strike(position: Vector3, power := 1.0) -> void:
	if chemistry != null and world != null:
		chemistry.strike(world, position, power)


func add_event_listener(watcher: Callable) -> void:
	event_watchers.append(watcher)


func _forward_events() -> void:
	for channel in world.pending_channels():
		for payload in world.drain(channel):
			for watcher in event_watchers:
				watcher.call(channel, payload)
			SystemBus.ecs_event.emit(channel, payload)


func _shutdown() -> void:
	world = null
	scheduler = EcsScheduler.new()
