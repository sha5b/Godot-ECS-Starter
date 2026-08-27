class_name UtilityAction
extends Resource

## A candidate behavior scored by utility.
##
## Final utility = compensated product of consideration scores (Dave Mark's
## infinite axis trick): many high scores reinforce each other, and the
## compensation factor keeps multi-consideration actions from always losing
## to single-consideration ones.

@export var action_name: StringName = &"idle"

@export var considerations: Array[Consideration] = []

## Baseline appeal before considerations apply.
@export_range(0.0, 1.0) var base_score := 0.5

## Scores below this never get selected.
@export_range(0.0, 1.0) var min_score := 0.02

## Seconds this action stays committed before it can be reconsidered freely.
@export var commit_time := 1.0

## Seconds before the action may be chosen again after it ends.
@export var cooldown := 0.0

## Emergency actions ignore commit_time and switch immediately when they win.
@export var is_interrupt := false


## Score this action against an agent blackboard (Input -> 0..1 value).
func score(blackboard: Dictionary) -> float:
	var product := base_score
	var count := 0
	for consideration in considerations:
		var value: float = blackboard.get(consideration.input, 0.0)
		product *= consideration.evaluate(value)
		count += 1
	if count == 0:
		return clampf(base_score, 0.0, 1.0)
	# Compensation: recover utility lost to multiplying many scores.
	var compensation := 1.0 - 1.0 / float(count)
	var make_up := (1.0 - product) * compensation
	return clampf(product + make_up * product, 0.0, 1.0)
