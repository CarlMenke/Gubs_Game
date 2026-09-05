extends Node
## The HUD over a real running match, in whatever state needs looking at.
## Development tool, not shipped.
##
## PLAN 4 has not happened yet, so there is no island to play the HUD over. This
## instances `tools/combat_range.tscn` — which already stands up a genuine
## offline match with a local Gub, spawned opponents and a working camera — and
## hangs `scenes/ui/hud.tscn` on top of it, exactly the way the arena is meant
## to. Every number the HUD shows therefore comes from the real `MatchState`,
## and only the *events* are staged.
##
## Extra names are written straight into `Net.players` and extra rows straight
## into `MatchState.stats`. Those are the same public dictionaries
## `combat_range` writes its dummies into: a scoreboard is not worth looking at
## with two rows in it, and no part of this reaches past an API the game uses.
##
##     Godot --path . --resolution 1600x900 --script tools/snapshot.gd -- \
##         res://tools/hud_range.tscn out.png 110 <mode>
##
## Modes: hud, hud_teams, hud_cooldown, killfeed, scoreboard, pause, results,
##        dead, spectate.

const RANGE_SCENE := preload("res://tools/combat_range.tscn")
const HUD_SCENE := preload("res://scenes/ui/hud.tscn")

## Well clear of the combat range's own 900s.
const EXTRA_BASE := 640
const EXTRA := [
	{"name": "Pipwick", "kills": 9, "deaths": 3},
	{"name": "Bramblewick", "kills": 6, "deaths": 5},
	{"name": "Mossback", "kills": 4, "deaths": 7},
	{"name": "Toadflax", "kills": 2, "deaths": 8},
	{"name": "Nettle", "kills": 1, "deaths": 9},
]

var _mode: String = "hud"
var _hud: CanvasLayer


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() >= 4:
		_mode = args[3]

	# The range starts the session in its own `_ready`, so it has to be in the
	# tree before anything below can touch the roster.
	add_child(RANGE_SCENE.instantiate())
	_hud = HUD_SCENE.instantiate()
	add_child(_hud)

	await get_tree().process_frame
	await get_tree().process_frame
	_stage()


func _stage() -> void:
	# The combat range turns the clock off, which is right for a firing range
	# and useless for photographing a HUD whose top-centre element is a clock.
	Net.config.time_limit = 600
	MatchState.time_left = 247.0
	Net.config.kill_limit = 15
	if _mode == "hud_teams":
		Net.config.mode = MatchConfig.Mode.TEAMS
		Net.config.team_count = 2
	if _mode == "hud_cooldown":
		# Long enough that the recharge is still visibly running when the
		# snapshot is taken; the range's own 1.5 s is over before then.
		Net.config.spear_recharge = 6.0
	if _mode == "spectate":
		Net.config.win_condition = MatchConfig.WinCondition.LIVES
		Net.config.lives = 3
	_populate_roster()

	match _mode:
		"killfeed", "scoreboard", "results":
			_stage_kills()
		"hud_cooldown":
			_stage_throw()
		"dead":
			_stage_kills()
			var dying: Dictionary = MatchState.stats.get(1, {})
			dying["alive"] = false
			MatchState.local_death.emit(Net.config.respawn_delay)
		"spectate":
			_stage_kills()
			var mine: Dictionary = MatchState.stats.get(1, {})
			mine["lives_left"] = 0
			mine["alive"] = false
			MatchState.local_death.emit(0.0)
		_:
			_stage_kills()

	MatchState.scores_changed.emit()

	match _mode:
		"scoreboard":
			(_hud.get_node("%Scoreboard") as Scoreboard).open()
		"pause":
			(_hud.get_node("%PauseMenu") as PauseMenu).open()
		"results":
			(_hud.get_node("%Results") as ResultsScreen).show_summary(_summary())


## Names and scores for people who are not actually here, so the scoreboard and
## the score line have something to rank.
func _populate_roster() -> void:
	var teams := Net.config.mode == MatchConfig.Mode.TEAMS
	if teams:
		Net.players[1]["team"] = 0
	for i in EXTRA.size():
		var peer_id := EXTRA_BASE + i
		Net.players[peer_id] = {
			"name": EXTRA[i]["name"], "team": i % 2 if teams else 0, "ready": true,
		}
		MatchState.stats[peer_id] = {
			"kills": EXTRA[i]["kills"], "deaths": EXTRA[i]["deaths"],
			"lives_left": Net.config.lives, "alive": i != 3,
			"respawn_at": 0.0, "last_attacker": 0, "last_attacker_at": -999.0,
		}
	# The local Gub needs a score of its own or every screen shows a zero.
	var mine: Dictionary = MatchState.stats.get(1, {})
	if not mine.is_empty():
		mine["kills"] = 7
		mine["deaths"] = 4
	Net.roster_changed.emit()


## A feed with one row in it proves nothing. Emitted rather than reported so
## the causes can be mixed — a spear kill, a fall, and one involving the local
## player, which is the row that has to stand out.
func _stage_kills() -> void:
	MatchState.player_killed.emit(EXTRA_BASE + 3, EXTRA_BASE, Gub.Cause.SPEAR)
	MatchState.player_killed.emit(EXTRA_BASE + 1, EXTRA_BASE + 1, Gub.Cause.VOID)
	MatchState.player_killed.emit(EXTRA_BASE + 2, 1, Gub.Cause.SPEAR)
	MatchState.player_killed.emit(1, EXTRA_BASE, Gub.Cause.SPEAR)


## Throw a real spear, so the crosshair ring and the spear slot are showing an
## actual `GubCombat` cooldown rather than a number this tool made up.
func _stage_throw() -> void:
	var gub := MatchState.local_gub()
	if gub == null:
		return
	var combat := gub.get_node_or_null("Combat") as GubCombat
	if combat != null:
		combat.try_throw_spear()


func _summary() -> Dictionary:
	return {
		"reason": "limit",
		"ranking": MatchState.ranking(),
		"stats": MatchState.stats,
		"mode": Net.config.mode,
	}
