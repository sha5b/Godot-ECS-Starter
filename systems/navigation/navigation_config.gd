class_name NavigationConfig
extends Node

## Configuration component for the NavigationSystem.

@export_group("NavMesh")
## Agent radius — how wide agents are (affects walkable area shrink)
@export var agent_radius: float = 1.0

## Agent height — how tall agents are
@export var agent_height: float = 2.0

## Maximum slope agents can walk on (degrees)
@export_range(0.0, 89.0) var agent_max_slope: float = 45.0

## Minimum ledge height that blocks navigation
@export var agent_max_climb: float = 0.5

## Cell size for navigation mesh voxelization (smaller = more precise, slower)
@export var cell_size: float = 1.0

## Cell height for navigation mesh voxelization
@export var cell_height: float = 0.5

@export_group("Performance")
## Maximum chunks to bake navigation for per frame
@export var max_bakes_per_frame: int = 1

## Whether to bake navigation asynchronously
@export var async_baking: bool = true
