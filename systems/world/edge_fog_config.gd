class_name EdgeFogConfig
extends Node

## Tunables for the volumetric edge fog ring.

## Wall distance beyond the loaded region (meters).
@export var thickness := 26.0

## Wall height — must cover the terrain grid (grid_min_y..grid_max_y).
@export var height := 82.0

## Volumetric density of each wall.
@export_range(0.0, 0.5) var density := 0.09

## Fog color — match the sky horizon so walls blend into the distance.
@export var fog_color := Color(0.7, 0.76, 0.85)
