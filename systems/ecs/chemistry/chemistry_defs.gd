class_name ChemistryDefs

## Shared enums for the chemistry engine. Kept in one place so components,
## rules, and systems never disagree about element or material values.

## Elements are the active forces of the world — the BotW chemistry engine's
## half of the interaction matrix.
enum Element {
	NONE,
	FIRE,
	ELECTRICITY,
	ICE,
	WATER,
	WIND,
}

## Channels the chemistry system publishes on.
const CHANNEL_IGNITED := &"chemistry.ignited"
const CHANNEL_BURNED_OUT := &"chemistry.burned_out"
const CHANNEL_EXTINGUISHED := &"chemistry.extinguished"
const CHANNEL_SHOCKED := &"chemistry.shocked"
const CHANNEL_FROZEN := &"chemistry.frozen"
const CHANNEL_STRIKE := &"chemistry.strike"
