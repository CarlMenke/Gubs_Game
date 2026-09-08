class_name MapCatalog
extends RefCounted
## Every map a match can be played on, and the one place that knows what kind of
## thing each one is.
##
## For the whole of development there was exactly one map — Whisperbloom Hollow,
## generated from `Net.config.map_seed` (D-007) — and so "the map" was spelled
## out separately in three files: `arena.gd` built it, `SceneFlow` named it on
## the loading card, and the lobby offered a seed for it. Adding a second map by
## editing all three is how two of them end up disagreeing about which map is
## loading. This table is the single answer and `MatchConfig.map` is the key
## into it.
##
## Entries are plain Dictionaries rather than Resources because they are read
## from `_ready` on every peer during a build that already blocks the main
## thread: a table of literals costs nothing to load and has no import step that
## can fail.
##
## The fields:
##
##   id            the string that travels in the match config. Never rename
##                 one. An unknown id falls back to `DEFAULT`, which is the
##                 right answer for garbage off the wire and the wrong one for
##                 a rename — the rename would silently move every saved lobby
##                 back to the island.
##   display_name  what the lobby picker and the loading card call it.
##   kind          PROCEDURAL: `arena.gd` generates the world from the seed.
##                 STATIC: `arena.gd` instances `scene` and asks it for spawns.
##   scene         empty for a procedural map; a `res://` path for a static one.
##   loading_line  the line under the title on the loading card. If it contains
##                 `%d` it is formatted with the map seed — a static map has no
##                 seed to name, so its line must not contain one.

enum Kind {
	PROCEDURAL,  ## grown from `Net.config.map_seed` by `arena.gd` itself
	STATIC,      ## a hand-made scene, instanced whole (see `static_map.gd`)
}

## What an unknown or missing id resolves to: the map that has always been here,
## and the only one that cannot fail to load because it has nothing on disk to
## load. `MAPS` must always contain it.
const DEFAULT := "hollow"

const MAPS: Array[Dictionary] = [
	{
		"id": "hollow",
		"display_name": "Whisperbloom Hollow",
		"kind": Kind.PROCEDURAL,
		"scene": "",
		"loading_line": "Growing the island from seed %d",
	},
	{
		"id": "rust",
		"display_name": "Rust",
		"kind": Kind.STATIC,
		"scene": "res://scenes/world/maps/rust.tscn",
		# No `%d`: a static map has no seed to name, and the card would print
		# the literal "%d" if this said one.
		"loading_line": "Unloading the containers",
	},
	# A static map is one more entry and nothing else in this file changes —
	# the lobby's picker, `SceneFlow`'s loading card and `arena.gd`'s branch all
	# read this table and none of them names a map.
	#
	# Do not add a row for a scene that is not on disk yet. Every scene a map
	# names is really loaded by `tools/playthrough.tscn`, so an entry pointing
	# at a file that has not landed fails the gate rather than waiting politely
	# for the art.
]


## The entry for `id`, or the default map's entry if nothing answers to it.
##
## Never returns empty, because every caller is mid-build with no useful way to
## handle "there is no map" — `arena.gd` is inside `_ready` and `SceneFlow` is
## mid-transition. `MatchConfig` sanitises the id on the way in, so by the time
## anything gets here a fallback means a bug or a peer from a future version,
## not a player choice being ignored.
static func get_entry(id: String) -> Dictionary:
	var found := _find(id)
	return found if not found.is_empty() else _find(DEFAULT)


## Every map id, in the order the lobby lists them. `ids()[n]` and
## `display_names()[n]` are the same map — that pairing is what lets the
## picker deal in indices while the config deals in ids.
static func ids() -> Array[String]:
	var out: Array[String] = []
	for entry: Dictionary in MAPS:
		out.append(String(entry["id"]))
	return out


static func display_names() -> Array[String]:
	var out: Array[String] = []
	for entry: Dictionary in MAPS:
		out.append(String(entry["display_name"]))
	return out


static func is_valid(id: String) -> bool:
	return not _find(id).is_empty()


## Whether this map is grown from the seed. The seed is meaningless for a static
## map, so this is what decides whether the lobby offers one and whether the
## loading card mentions it.
static func is_procedural(id: String) -> bool:
	return int(get_entry(id)["kind"]) == Kind.PROCEDURAL


static func _find(id: String) -> Dictionary:
	for entry: Dictionary in MAPS:
		if String(entry["id"]) == id:
			return entry
	return {}
