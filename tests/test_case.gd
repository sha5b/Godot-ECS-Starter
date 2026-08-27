class_name EcsTestCase
extends RefCounted

## Minimal assert harness for the headless test runner.
## No addons, no dependencies — Godot-native only.

var failures: Array[String] = []
var _current_test := "<none>"


func run_all() -> Dictionary:
	var methods := get_method_list()
	var passed := 0
	var failed := 0
	for method in methods:
		var method_name: String = method["name"]
		if not method_name.begins_with("test_"):
			continue
		_current_test = method_name
		var before := failures.size()
		call(method_name)
		if failures.size() == before:
			passed += 1
			print("  [PASS] %s" % method_name)
		else:
			failed += 1
	return {"passed": passed, "failed": failed}


# ── Asserts ──────────────────────────────────────────────────────────────────


func assert_true(condition: bool, message := "expected true") -> void:
	if not condition:
		_fail(message)


func assert_false(condition: bool, message := "expected false") -> void:
	if condition:
		_fail(message)


func assert_equal(actual: Variant, expected: Variant, message := "") -> void:
	if actual != expected:
		_fail("%s — expected '%s', got '%s'" % [message, str(expected), str(actual)])


func assert_almost(actual: float, expected: float, epsilon := 0.0001, message := "") -> void:
	if absf(actual - expected) > epsilon:
		_fail("%s — expected ~%f, got %f" % [message, expected, actual])


func assert_not_null(value: Variant, message := "expected non-null") -> void:
	if value == null:
		_fail(message)


func assert_null(value: Variant, message := "expected null") -> void:
	if value != null:
		_fail(message)


func fail_test(message: String) -> void:
	_fail(message)


func _fail(message: String) -> void:
	failures.append("[%s] %s" % [_current_test, message])
	print("  [FAIL] %s — %s" % [_current_test, message])
