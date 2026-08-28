class_name UtilityBrain
extends Resource

## The action set of one agent archetype. Inspector-editable; code-spawned
## agents use the factory helpers below.

## A new action must beat the committed action's score by this factor to
## take over (hysteresis — agents don't dither between behaviors).
@export_range(1.0, 3.0) var switch_margin := 1.35

@export var actions: Array[UtilityAction] = []


func action_by_name(action_name: StringName) -> UtilityAction:
	for action in actions:
		if action.action_name == action_name:
			return action
	return null


func best_action(blackboard: Dictionary) -> UtilityAction:
	var best: UtilityAction = null
	var best_score := 0.0
	for action in actions:
		var score := action.score(blackboard)
		if score > best_score:
			best_score = score
			best = action
	if best != null and best_score < best.min_score:
		return null
	return best


# ── Factories ────────────────────────────────────────────────────────────────


static func critter_brain() -> UtilityBrain:
	## A foraging animal: eats, wanders, rests, panics around fire, and runs
	## from anything that hunts it.
	var brain := UtilityBrain.new()
	brain.actions = [
		_make(&"panic",
			[[Consideration.SensorInput.FIRE_PROXIMITY, Consideration.ResponseCurve.STEP, {}]],
			0.9, true),
		# Above flee and below panic: a predator outranks the camera, fire
		# outranks everything. Interrupt, because prey that finishes its
		# current action before reacting is prey that gets eaten.
		_make(&"evade",
			[[Consideration.SensorInput.PREDATOR_PROXIMITY, Consideration.ResponseCurve.POLYNOMIAL, {"exponent": 1.6}]],
			0.85, true),
		_make(&"flee",
			[[Consideration.SensorInput.THREAT_PROXIMITY, Consideration.ResponseCurve.POLYNOMIAL, {"exponent": 2.0}]],
			0.4),
		_make(&"seek_food",
			[
				[Consideration.SensorInput.HUNGER, Consideration.ResponseCurve.POLYNOMIAL, {"exponent": 1.5}],
				[Consideration.SensorInput.FOOD_PROXIMITY, Consideration.ResponseCurve.LINEAR, {}],
			],
			0.45),
		_make(&"rest",
			[
				[Consideration.SensorInput.ENERGY, Consideration.ResponseCurve.INVERSE, {}],
			],
			0.2),
		_make(&"wander",
			[[Consideration.SensorInput.CONSTANT, Consideration.ResponseCurve.LINEAR, {"weight": 0.4}]],
			0.2),
	]
	return brain


static func predator_brain() -> UtilityBrain:
	## A hunter. Everything the forager does, plus hunting — and its hunger
	## drives it toward prey rather than toward plants.
	##
	## Hunting is scored by hunger AND prey proximity, so a fed predator
	## ignores a herd it is standing in. That is what stops a wolf lineage
	## from clearing a map: predation is bounded by appetite, not opportunity.
	var brain := UtilityBrain.new()
	brain.actions = [
		_make(&"panic",
			[[Consideration.SensorInput.FIRE_PROXIMITY, Consideration.ResponseCurve.STEP, {}]],
			0.9, true),
		_make(&"hunt",
			[
				[Consideration.SensorInput.HUNGER, Consideration.ResponseCurve.POLYNOMIAL, {"exponent": 1.4}],
				[Consideration.SensorInput.PREY_PROXIMITY, Consideration.ResponseCurve.LINEAR, {}],
			],
			0.8),
		_make(&"evade",
			[[Consideration.SensorInput.PREDATOR_PROXIMITY, Consideration.ResponseCurve.POLYNOMIAL, {"exponent": 1.6}]],
			0.7, true),
		_make(&"seek_food",
			[
				[Consideration.SensorInput.HUNGER, Consideration.ResponseCurve.POLYNOMIAL, {"exponent": 2.0}],
				[Consideration.SensorInput.FOOD_PROXIMITY, Consideration.ResponseCurve.LINEAR, {}],
			],
			0.25),
		_make(&"rest",
			[[Consideration.SensorInput.ENERGY, Consideration.ResponseCurve.INVERSE, {}]],
			0.25),
		_make(&"wander",
			[[Consideration.SensorInput.CONSTANT, Consideration.ResponseCurve.LINEAR, {"weight": 0.4}]],
			0.2),
	]
	return brain


## The brain a species should use.
##
## A predator brain needs something to hunt, not just a carnivorous diet — an
## omnivore with an empty prey list is a forager, and giving it `hunt` only
## means scoring an action that can never fire. Measured: 29 of 63 animals
## carried a predator brain when only 8 of them had any prey.
static func for_record(record: SpeciesRecord) -> UtilityBrain:
	if record != null and record.is_carnivore() and not record.prey.is_empty():
		return predator_brain()
	return critter_brain()


static func _make(action_name: StringName, spec: Array, base: float,
		is_interrupt := false) -> UtilityAction:
	var action := UtilityAction.new()
	action.action_name = action_name
	action.base_score = base
	action.is_interrupt = is_interrupt
	action.commit_time = 1.5
	action.cooldown = 0.5
	for entry in spec:
		var consideration := Consideration.new()
		if entry is Array:
			consideration.input = entry[0]
			consideration.curve = entry[1]
			for key in entry[2]:
				consideration.set(key, entry[2][key])
		else:
			consideration.input = entry
		action.considerations.append(consideration)
	return action
