extends SceneTree

## Headless unit test runner.
##
## Run from the project root:
##   godot --headless --path . --script tests/run_tests.gd
##
## Discovers every tests/unit/test_*.gd, runs its test_ methods, prints a
## report, and exits non-zero on any failure (CI-friendly).


func _initialize() -> void:
	var test_dir := "res://tests/unit"
	var files: Array[String] = []
	var dir := DirAccess.open(test_dir)
	if dir == null:
		push_error("[Tests] missing directory %s" % test_dir)
		quit(1)
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name.begins_with("test_") and file_name.ends_with(".gd"):
			files.append(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
	files.sort()

	var total_passed := 0
	var total_failed := 0
	print("\n=== ECS test run ===")
	for file in files:
		print("\n%s" % file)
		var result: Dictionary = _run_suite("%s/%s" % [test_dir, file])
		total_passed += result["passed"]
		total_failed += result["failed"]

	print("\n=== %d passed, %d failed ===\n" % [total_passed, total_failed])
	quit(0 if total_failed == 0 else 1)


## One file per call: a broken script fails its suite without aborting the
## whole runner (a top-level runtime error would leave the engine idling).
func _run_suite(path: String) -> Dictionary:
	var script: GDScript = load(path)
	if script == null or not script.can_instantiate():
		print("  [ERROR] could not load/instantiate %s" % path)
		return {"passed": 0, "failed": 1}
	var case: EcsTestCase = script.new()
	return case.run_all()
