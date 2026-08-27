class_name EcsScheduler
extends RefCounted

## Ordered, profiled execution of registered systems across phases.
##
## Command buffer flushes happen at phase boundaries so each phase observes
## a consistent structure — the same sync-point discipline BotW uses between
## its actor update passes.

enum Phase { EARLY, SIM, LATE, VIEW }

const PHASE_COUNT := 4

var frame := 0

var _entries: Array[Dictionary] = []  ## {name, phase, priority, callable, last_us, avg_us}
var _sorted := true

## Microseconds each system took last tick, keyed by system name.
var system_times: Dictionary = {}


func register(system_name: StringName, callable: Callable, phase: Phase, priority: int) -> void:
	_entries.append({
		"name": system_name,
		"phase": phase,
		"priority": priority,
		"callable": callable,
		"last_us": 0,
		"avg_us": 0.0,
	})
	_sorted = false


func tick(world: EcsWorld, delta: float) -> void:
	frame += 1
	if not _sorted:
		_entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if a["phase"] != b["phase"]:
				return a["phase"] < b["phase"]
			return a["priority"] < b["priority"]
		)
		_sorted = true

	var last_phase := -1
	for entry in _entries:
		if last_phase != -1 and entry["phase"] != last_phase:
			world.flush_commands()
		last_phase = entry["phase"]
		var t0 := Time.get_ticks_usec()
		entry["callable"].call(world, delta, frame)
		entry["last_us"] = Time.get_ticks_usec() - t0
		entry["avg_us"] = lerpf(entry["avg_us"], entry["last_us"], 0.1)
		system_times[entry["name"]] = entry["last_us"]
	world.flush_commands()
