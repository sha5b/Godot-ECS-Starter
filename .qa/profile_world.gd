extends Node

## In-situ profiler: loads the real main scene, samples frame time,
## ECS entity counts and per-system microseconds, then reports.

var _samples: Array[float] = []
var _elapsed := 0.0
var _report_at := 5.0
var _duration := 150.0

func _ready() -> void:
	print("[QA] profiling main.tscn for %.0fs" % _duration)

func _process(delta: float) -> void:
	_elapsed += delta
	_samples.append(delta)
	if _elapsed >= _report_at:
		_report_at += 5.0
		_dump()
	if _elapsed >= _duration:
		_dump()
		print("[QA] done")
		get_tree().quit()

func _dump() -> void:
	var recent := _samples.slice(maxi(0, _samples.size() - 300))
	recent.sort()
	var avg := 0.0
	for s in recent: avg += s
	avg /= maxf(1.0, recent.size())
	var p95: float = recent[mini(recent.size() - 1, int(recent.size() * 0.95))]
	var worst: float = recent[recent.size() - 1]
	var chunks := 0
	for n in get_tree().get_nodes_in_group(&"ecs_systems"):
		if n.name == "ChunkManager" and n.has_method("get_chunk_count"):
			chunks = n.get_chunk_count()
		elif n.name == "ChunkManager":
			var d = n.get("_chunks")
			if d is Dictionary: chunks = (d as Dictionary).size()
	var stats: Dictionary = SharedWorld.ecs_stats
	var ents: int = stats.get("entities", -1)
	var tiers = stats.get("tier_counts", [])
	var times: Dictionary = stats.get("system_times_us", {})
	var hot := ""
	var keys := times.keys()
	keys.sort_custom(func(a, b): return times[a] > times[b])
	for k in keys.slice(0, 5):
		hot += " %s=%.1fms" % [k, times[k] / 1000.0]
	print("[QA] t=%5.1fs avg=%6.2fms p95=%6.2fms | chunks=%4d ents=%6d tiers=%s |%s" % [
		_elapsed, avg * 1000.0, p95 * 1000.0, chunks, ents, str(tiers), hot])
