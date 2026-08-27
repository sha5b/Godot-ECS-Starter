class_name CAgent
extends RefCounted

## Utility-AI agent component.
##
## The agent carries its drives (hunger, energy) and its committed action.
## UtilityAISystem scores the brain's actions each AI tick and commits to
## the winner; actuators then translate the action into movement intents.

const COMPONENT_ID := &"CAgent"

## The UtilityBrain resource with scored actions. Assigned at spawn.
var brain: UtilityBrain

# --- Drives (0..1) ---
var hunger := 0.3
var energy := 1.0

# --- Action state ---
var current_action := &"idle"
var action_time := 0.0
var action_score := 0.0
var target_entity := 0
var target_position := Vector3.ZERO

## Cooldowns per action name: StringName -> seconds remaining.
var cooldowns: Dictionary = {}

## Sensor blackboard refreshed each AI tick: input enum -> 0..1 value.
var blackboard: Dictionary = {}

var move_speed := 2.0


func is_on_cooldown(action: StringName) -> bool:
	return float(cooldowns.get(action, 0.0)) > 0.0


func tick_cooldowns(delta: float) -> void:
	for key in cooldowns:
		cooldowns[key] = maxf(float(cooldowns[key]) - delta, 0.0)
