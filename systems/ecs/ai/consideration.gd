class_name Consideration
extends Resource

## One scored input of a utility action.
##
## BotW-style AI doesn't run behavior trees — every action scores a set of
## considerations (response curves over normalized inputs) and the highest
## utility wins. Each consideration maps a 0..1 input through a curve to a
## 0..1 score that multiplies into the action's final utility.
##
## Enums are named SensorInput / ResponseCurve because Input and Curve
## would collide with Godot's built-in classes in typed contexts.

enum SensorInput {
	HUNGER,
	ENERGY,
	THREAT_PROXIMITY,  ## close threat -> 1
	FOOD_PROXIMITY,  ## close food -> 1
	FIRE_PROXIMITY,  ## close fire -> 1
	IS_FROZEN,
	IS_BURNING,
	CONSTANT,
}

enum ResponseCurve {
	LINEAR,
	POLYNOMIAL,  ## value^exponent
	INVERSE,  ## 1 - value
	LOGISTIC,  ## s-curve around midpoint
	STEP,  ## 0 below threshold, 1 above
}

@export var input: SensorInput = SensorInput.CONSTANT

@export var curve: ResponseCurve = ResponseCurve.LINEAR

@export var exponent := 1.0
@export var midpoint := 0.5
@export var steepness := 8.0
@export var threshold := 0.5

## Flat multiplier applied after the curve.
@export_range(0.0, 2.0) var weight := 1.0


## Map a normalized input to this consideration's 0..1 score.
func evaluate(value01: float) -> float:
	var v := clampf(value01, 0.0, 1.0)
	var out := 0.0
	match curve:
		ResponseCurve.LINEAR:
			out = v
		ResponseCurve.POLYNOMIAL:
			out = pow(v, maxf(exponent, 0.01))
		ResponseCurve.INVERSE:
			out = 1.0 - v
		ResponseCurve.LOGISTIC:
			out = 1.0 / (1.0 + exp(-steepness * (v - midpoint)))
		ResponseCurve.STEP:
			out = 1.0 if v >= threshold else 0.0
	return clampf(out * weight, 0.0, 1.0)
