class_name CTransform
extends RefCounted

## Spatial component. The ECS owns the truth; view nodes only mirror it.

const COMPONENT_ID := &"CTransform"

var position := Vector3.ZERO
var facing := 0.0
var uniform_scale := 1.0


func face_towards(target: Vector3, delta: float, turn_speed: float = 6.0) -> void:
	var to_target := target - position
	if absf(to_target.x) < 0.001 and absf(to_target.z) < 0.001:
		return
	var wanted := atan2(to_target.x, to_target.z)
	var diff := angle_difference(facing, wanted)
	facing += clampf(diff, -turn_speed * delta, turn_speed * delta)
