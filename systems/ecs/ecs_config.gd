class_name EcsConfig
extends Node

## Inspector-first tuning for the ECS runtime, following the config-child
## doctrine. Drop different values here to reshape the whole simulation.

## Which subsystems run at all.
@export var tiering_enabled := true
@export var movement_enabled := true
@export var ai_enabled := true
@export var chemistry_enabled := true
@export var vitality_enabled := true
@export var view_sync_enabled := true

## Tier distances from the focus (camera/player), BotW A/B/C style.
@export var tier_near_distance := 40.0
@export var tier_mid_distance := 120.0
@export var tier_far_distance := 300.0
@export var tier_recheck_frames := 15

## Actors are confined inside this radius around the origin (0 = unbounded).
@export var movement_bounds_radius := 0.0

## Chemistry rulebook. Swap for a custom Resource to change world physics.
@export var chemistry_rules: ChemistryRules

## AI sensor ranges.
@export var ai_sensor_range := 24.0
@export var ai_threat_range := 7.0


func _ready() -> void:
	if chemistry_rules == null:
		chemistry_rules = ChemistryRules.new()
		chemistry_rules.default_rules()
