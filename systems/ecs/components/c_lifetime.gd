class_name CLifetime
extends RefCounted

## Lifetime component. Entity despawns when the timer reaches zero.
## Used for transient effects like lightning strike anchors.

const COMPONENT_ID := &"CLifetime"

var remaining := 1.0
