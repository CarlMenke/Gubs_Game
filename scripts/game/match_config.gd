class_name MatchConfig
extends Resource
## Everything about a match that the host can dial in from the lobby.
##
## The host owns the authoritative copy. It is pushed to clients as a plain
## Dictionary (see `to_dict`/`apply_dict`) rather than as a Resource, because
## sending Resources over RPC means allowing object decoding on the wire — an
## easy way to hand a malicious peer arbitrary object construction. A flat
## dictionary of primitives, validated on arrival, has no such hole.

enum Mode {
	FREE_FOR_ALL,
	TEAMS,
}

enum WinCondition {
	KILL_LIMIT,   ## first to N kills
	LIVES,        ## last Gub (or team) standing
	TIME_ONLY,    ## highest score when the clock runs out
}

const MIN_PLAYERS := 1
const MAX_PLAYERS := 8
const TEAM_NONE := -1

@export var mode: Mode = Mode.FREE_FOR_ALL
@export var win_condition: WinCondition = WinCondition.KILL_LIMIT
@export_range(1, 8) var team_count: int = 2

## Scoring limits. Only the one matching `win_condition` is enforced, but all
## are kept so toggling the condition in the lobby does not lose your settings.
@export_range(1, 50) var kill_limit: int = 15
@export_range(1, 15) var lives: int = 3
## Seconds. Zero means no time limit (invalid for TIME_ONLY).
@export_range(0, 3600) var time_limit: int = 600

@export var friendly_fire: bool = false
@export_range(0.0, 10.0) var respawn_delay: float = 3.0
@export_range(0.0, 10.0) var spawn_protection: float = 2.0
@export_range(0.0, 30.0) var warmup_time: float = 5.0

## Spears are the only weapon and always instant-kill, so the recharge time is
## the single most important balance dial in the game: it sets how often a Gub
## can commit to an attack, and therefore how punishing a miss is.
@export_range(0.5, 15.0) var spear_recharge: float = 3.0

@export_range(1.0, 60.0) var mushroom_cooldown: float = 12.0
@export_range(2.0, 120.0) var mushroom_lifetime: float = 25.0
@export_range(1, 5) var mushroom_max_active: int = 2

@export_range(1.0, 60.0) var lure_cooldown: float = 18.0
@export_range(2.0, 25.0) var lure_radius: float = 9.0
@export_range(0.2, 5.0) var lure_hold: float = 1.4
@export_range(1.0, 60.0) var lure_pull_strength: float = 18.0
## The delay between the lure landing and the pull firing — the window in which
## seeing it land is worth anything. This defaulted to 0.35 while its own range
## started at 0.5, so `_clamp_all` silently raised every fresh config to 0.5 and
## the declared default was never the value anyone actually played with. The
## range wins: half a second is already a short fuse.
@export_range(0.5, 5.0) var lure_fuse: float = 0.5

@export_range(MIN_PLAYERS, MAX_PLAYERS) var max_players: int = MAX_PLAYERS

## Seed for the island generator. Every client builds the map from this, so it
## must be identical everywhere — it is replicated with the rest of the config.
@export var map_seed: int = 20260904


const _FIELDS := [
	"mode", "win_condition", "team_count", "kill_limit", "lives", "time_limit",
	"friendly_fire", "respawn_delay", "spawn_protection", "warmup_time",
	"spear_recharge", "mushroom_cooldown", "mushroom_lifetime", "mushroom_max_active",
	"lure_cooldown", "lure_radius", "lure_hold", "lure_pull_strength", "lure_fuse",
	"max_players", "map_seed",
]


func to_dict() -> Dictionary:
	var out := {}
	for field: String in _FIELDS:
		out[field] = get(field)
	return out


## Copy values in from an untrusted dictionary, clamped to the ranges declared
## above. Unknown keys are ignored and missing keys keep their current value.
func apply_dict(data: Dictionary) -> void:
	for field: String in _FIELDS:
		if not data.has(field):
			continue
		var incoming: Variant = data[field]
		var current: Variant = get(field)
		if typeof(incoming) != typeof(current):
			# Ints and floats are interchangeable often enough to be worth coercing.
			if typeof(current) == TYPE_FLOAT and typeof(incoming) == TYPE_INT:
				incoming = float(incoming)
			elif typeof(current) == TYPE_INT and typeof(incoming) == TYPE_FLOAT:
				incoming = int(incoming)
			else:
				continue
		set(field, incoming)
	_clamp_all()


func duplicate_config() -> MatchConfig:
	var copy := MatchConfig.new()
	copy.apply_dict(to_dict())
	return copy


func _clamp_all() -> void:
	mode = clampi(mode, 0, Mode.size() - 1) as Mode
	win_condition = clampi(win_condition, 0, WinCondition.size() - 1) as WinCondition
	team_count = clampi(team_count, 2, 8)
	kill_limit = clampi(kill_limit, 1, 50)
	lives = clampi(lives, 1, 15)
	time_limit = clampi(time_limit, 0, 3600)
	respawn_delay = clampf(respawn_delay, 0.0, 10.0)
	spawn_protection = clampf(spawn_protection, 0.0, 10.0)
	warmup_time = clampf(warmup_time, 0.0, 30.0)
	spear_recharge = clampf(spear_recharge, 0.5, 15.0)
	mushroom_cooldown = clampf(mushroom_cooldown, 1.0, 60.0)
	mushroom_lifetime = clampf(mushroom_lifetime, 2.0, 120.0)
	mushroom_max_active = clampi(mushroom_max_active, 1, 5)
	lure_cooldown = clampf(lure_cooldown, 1.0, 60.0)
	lure_radius = clampf(lure_radius, 2.0, 25.0)
	lure_hold = clampf(lure_hold, 0.2, 5.0)
	lure_pull_strength = clampf(lure_pull_strength, 1.0, 60.0)
	lure_fuse = clampf(lure_fuse, 0.5, 5.0)
	max_players = clampi(max_players, MIN_PLAYERS, MAX_PLAYERS)
	# TIME_ONLY with no clock would never end.
	if win_condition == WinCondition.TIME_ONLY and time_limit <= 0:
		time_limit = 600


## Human-readable one-liner for the lobby header.
func summary() -> String:
	var parts: Array[String] = []
	parts.append("Free-for-all" if mode == Mode.FREE_FOR_ALL else "%d Teams" % team_count)
	match win_condition:
		WinCondition.KILL_LIMIT:
			parts.append("%d kills" % kill_limit)
		WinCondition.LIVES:
			parts.append("%d lives" % lives)
		WinCondition.TIME_ONLY:
			parts.append("timed")
	if time_limit > 0:
		parts.append("%d:%02d" % [time_limit / 60, time_limit % 60])
	if mode == Mode.TEAMS and friendly_fire:
		parts.append("friendly fire")
	return "  ·  ".join(parts)
