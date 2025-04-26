# Godot ECS System

## Overview
This is a simple Entity Component System (ECS) implementation for Godot 4.3. The ECS architecture separates game objects (entities) from their data (components) and behavior (systems).

## Core Classes

### World
The World class manages all entities, components, and systems. It handles:
- Creating entities
- Adding components to entities
- Querying entities with specific component combinations
- Running systems each frame

### Entity
A simple wrapper around an entity ID.

### Component
Base class for all components. Components should be data-only classes that inherit from this.

### System
Base class for all systems. Systems operate on entities with specific combinations of components.

## Usage

1. Create component types by extending the Component class
2. Create systems by extending the System class
3. Create a World instance
4. Add entities with components to the world
5. Add systems to the world

## Example

```gdscript
# Create components
var position_comp = PositionComponent.new(Vector2(100, 100))
var sprite_comp = SpriteComponent.new("res://assets/character.png")

# Create entity and add components
var world = World.new()
var entity = world.create_entity()
world.add_component(entity, position_comp)
world.add_component(entity, sprite_comp)

# Add systems
world.add_system(MovementSystem.new())
world.add_system(RenderSystem.new())
```

The systems will automatically process entities with the appropriate components each frame.