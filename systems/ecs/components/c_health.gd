class_name CHealth
extends RefCounted

## Health component. Chemistry damage (burning, shocks) lands here.

const COMPONENT_ID := &"CHealth"

var max_hp := 10.0
var hp := 10.0
var dead := false


func apply_damage(amount: float) -> void:
	if dead:
		return
	hp = maxf(hp - amount, 0.0)
	if hp <= 0.0:
		dead = true


func heal(amount: float) -> void:
	if dead:
		return
	hp = minf(hp + amount, max_hp)
