extends SceneTree

func _init() -> void:
	root.ready.connect(_go, CONNECT_ONE_SHOT)

func _go() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	var main: Node = packed.instantiate()
	root.add_child(main)
	current_scene = main
	var qa_script: GDScript = load("res://.qa/visual_qa.gd")
	var qa: Node = qa_script.new()
	root.add_child(qa)
