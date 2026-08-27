extends SceneTree

func _init() -> void:
	root.ready.connect(_go, CONNECT_ONE_SHOT)

func _go() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	var main: Node = packed.instantiate()
	root.add_child(main)
	var probe_script: GDScript = load("res://.qa/profile_world.gd")
	var probe: Node = probe_script.new()
	root.add_child(probe)
