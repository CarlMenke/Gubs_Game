extends Node
## Exercises the match rules end to end and asserts the outcomes.
## Development tool, not shipped. Runs headless in a couple of seconds.
##
##   Godot --headless --path . tools/match_rules.tscn
##
## Note this runs as a *scene*, not as a `--script` main loop. A script main
## loop is compiled before the autoloads are registered, so `MatchState` and
## `Net` are not resolvable identifiers at parse time and the whole file fails
## to compile — which is also why `snapshot.gd` only ever loads scenes by path.
##
## `combat_range` proves a spear can kill someone. It cannot prove that fifteen
## kills ends a match, that a friendly-fire kill costs a point instead of
## earning one, or that the last Gub standing wins — those live entirely in
## `MatchState` and, until this existed, had never been run with more than one
## live player. Every scenario drives the same host-side API a real match drives
## (`report_kill`, the clock, the respawn tick), so a rule that passes here is a
## rule that works in a match.
##
## Gubs are deliberately never spawned. These scenarios are about the
## bookkeeping, so the arena is registered with an empty spawn list and
## `_create_gub` is left to fail quietly for peers that do not exist.

const PEERS := [1, 901, 902, 903]

var _failures: int = 0
var _checks: int = 0


func _ready() -> void:
	print("match_rules: starting")
	_run_kill_limit()
	_run_friendly_fire_off()
	_run_friendly_fire_on()
	_run_team_kill_limit()
	_run_lives_elimination()
	_run_time_limit()
	_run_void_credit()
	_run_spawn_protection()
	_run_config_validation()

	print("match_rules: %d checks, %d failures" % [_checks, _failures])
	print("match_rules: %s" % ("PASS" if _failures == 0 else "FAIL"))
	# Free the Gubs the scenarios spawned before quitting: Godot reports
	# anything still in the tree at exit as a leak, and a harness that prints
	# PASS above a wall of warnings teaches people to ignore warnings.
	# queue_free lands at the end of a frame and the corpses and spears take
	# another to unwind, hence the wait.
	#
	# A dozen or so still get reported and always will — they are the `preload`
	# constants on the item and audio scripts, which are alive for as long as
	# the scripts are. Nothing here can release those, so the count never quite
	# reaches zero.
	MatchState.reset()
	for i in 4:
		await get_tree().process_frame
	get_tree().quit(1 if _failures > 0 else 0)


# ------------------------------------------------------------------ harness ---

## Put `Net` and `MatchState` into a running match with `count` fake players.
## Teams are assigned round-robin, so team scenarios get two of each.
func _begin(count: int, configure: Callable) -> void:
	MatchState.reset()
	Net.start_offline()
	Net.players.clear()
	for i in count:
		Net.players[PEERS[i]] = {
			"name": "P%d" % i, "team": i % 2, "ready": true,
		}
	Net.roster_changed.emit()
	# Every scenario starts from a clean, fast config. Spawn protection in
	# particular has to be switched off explicitly: it defaults to two seconds,
	# these scenarios run in microseconds, and a protected Gub correctly refuses
	# to die — which looked exactly like the scoring being broken the first time
	# this harness was run. `_run_spawn_protection` turns it back on deliberately.
	Net.config.spawn_protection = 0.0
	Net.config.warmup_time = 0.0
	Net.config.respawn_delay = 0.0
	configure.call(Net.config)
	# Registering the arena is what starts a match.
	MatchState.register_arena(self, [] as Array[Transform3D])
	# Warmup is skipped rather than waited out: these scenarios are about the
	# rules, not the countdown.
	MatchState.phase = MatchState.Phase.PLAYING


func _kill(victim: int, killer: int) -> void:
	MatchState.report_kill(victim, killer, Gub.Cause.SPEAR,
		Vector3.ZERO, Vector3.FORWARD, "spine.002")


## Bring a dead player back without needing a Gub or a respawn timer.
func _revive(peer_id: int) -> void:
	MatchState.stats[peer_id]["alive"] = true
	MatchState.stats[peer_id]["respawn_at"] = 0.0


func _check(what: String, got: Variant, want: Variant) -> void:
	_checks += 1
	if got == want:
		return
	_failures += 1
	print("  FAIL  %s: got %s, wanted %s" % [what, str(got), str(want)])


func _scenario(scenario_name: String) -> void:
	print("-- %s" % scenario_name)


## First entry of a summary array, or -1 if the match never finished. Reading
## `[0]` directly turns one failed assertion into a crash that hides the rest.
func _leader(summary: Dictionary) -> int:
	var order: Array = summary.get("ranking", [])
	return int(order[0]) if not order.is_empty() else -1


# ---------------------------------------------------------------- scenarios ---

func _run_kill_limit() -> void:
	_scenario("free-for-all, kill limit")
	var finished := {}
	_begin(3, func(c: MatchConfig) -> void:
		c.mode = MatchConfig.Mode.FREE_FOR_ALL
		c.win_condition = MatchConfig.WinCondition.KILL_LIMIT
		c.kill_limit = 3
		c.time_limit = 0)
	MatchState.match_finished.connect(func(s: Dictionary) -> void:
		finished.merge(s, true), CONNECT_ONE_SHOT)

	for i in 2:
		_kill(901, 1)
		_revive(901)
	_check("not finished at 2 of 3", MatchState.phase, MatchState.Phase.PLAYING)
	_check("killer has 2", MatchState.kills(1), 2)
	_check("victim has 2 deaths", MatchState.deaths(901), 2)

	_kill(901, 1)
	_check("finished at the limit", MatchState.phase, MatchState.Phase.POST_MATCH)
	_check("reason", finished.get("reason"), "limit")
	_check("winner leads the ranking", _leader(finished), 1)

	# A kill after the whistle must not count.
	_kill(902, 1)
	_check("no scoring after the match ends", MatchState.kills(1), 3)


func _run_friendly_fire_off() -> void:
	_scenario("teams, friendly fire off")
	_begin(4, func(c: MatchConfig) -> void:
		c.mode = MatchConfig.Mode.TEAMS
		c.team_count = 2
		c.win_condition = MatchConfig.WinCondition.KILL_LIMIT
		c.kill_limit = 50
		c.friendly_fire = false
		c.time_limit = 0)
	# Peers 1 and 902 are team 0; 901 and 903 are team 1.
	_kill(902, 1)
	_check("team-mate survives", MatchState.is_alive(902), true)
	_check("no death recorded", MatchState.deaths(902), 0)
	_check("no point awarded", MatchState.kills(1), 0)

	_kill(901, 1)
	_check("an enemy still dies", MatchState.is_alive(901), false)
	_check("and still scores", MatchState.kills(1), 1)


func _run_friendly_fire_on() -> void:
	_scenario("teams, friendly fire on")
	_begin(4, func(c: MatchConfig) -> void:
		c.mode = MatchConfig.Mode.TEAMS
		c.team_count = 2
		c.win_condition = MatchConfig.WinCondition.KILL_LIMIT
		c.kill_limit = 50
		c.friendly_fire = true
		c.time_limit = 0)
	_kill(902, 1)
	_check("team-mate dies", MatchState.is_alive(902), false)
	_check("and it costs a point", MatchState.kills(1), -1)


func _run_team_kill_limit() -> void:
	_scenario("teams, the limit is a team total")
	var finished := {}
	_begin(4, func(c: MatchConfig) -> void:
		c.mode = MatchConfig.Mode.TEAMS
		c.team_count = 2
		c.win_condition = MatchConfig.WinCondition.KILL_LIMIT
		c.kill_limit = 3
		c.friendly_fire = false
		c.time_limit = 0)
	MatchState.match_finished.connect(func(s: Dictionary) -> void:
		finished.merge(s, true), CONNECT_ONE_SHOT)

	# Two kills by one team-mate and one by the other reaches a team limit of 3
	# that neither player reaches alone — the whole point of the mode.
	_kill(901, 1)
	_revive(901)
	_kill(903, 1)
	_revive(903)
	_check("still playing at 2", MatchState.phase, MatchState.Phase.PLAYING)
	_kill(901, 902)
	_check("team score", MatchState.team_score(0), 3)
	_check("finished on the team total", MatchState.phase, MatchState.Phase.POST_MATCH)
	_check("team scores in the summary",
		(finished.get("team_scores", {}) as Dictionary).get(0), 3)


func _run_lives_elimination() -> void:
	_scenario("lives, last Gub standing")
	var finished := {}
	_begin(3, func(c: MatchConfig) -> void:
		c.mode = MatchConfig.Mode.FREE_FOR_ALL
		c.win_condition = MatchConfig.WinCondition.LIVES
		c.lives = 2
		c.kill_limit = 50
		c.time_limit = 0)
	MatchState.match_finished.connect(func(s: Dictionary) -> void:
		finished.merge(s, true), CONNECT_ONE_SHOT)

	_check("everyone starts with 2 lives", MatchState.lives_left(901), 2)
	_kill(901, 1)
	_check("a death costs a life", MatchState.lives_left(901), 1)
	_revive(901)
	_kill(901, 1)
	_check("out of lives", MatchState.lives_left(901), 0)
	_check("still playing, one rival left", MatchState.phase, MatchState.Phase.PLAYING)

	_kill(902, 1)
	_revive(902)
	_kill(902, 1)
	_check("finished when only one is left", MatchState.phase, MatchState.Phase.POST_MATCH)
	_check("reason", finished.get("reason"), "elimination")
	_check("survivor leads", _leader(finished), 1)

	# An eliminated player must not come back when the respawn timer matures.
	MatchState.stats[901]["respawn_at"] = 0.001
	MatchState.phase = MatchState.Phase.PLAYING
	MatchState._tick_respawns()
	_check("eliminated players stay out", MatchState.is_alive(901), false)


func _run_time_limit() -> void:
	_scenario("the clock")
	var finished := {}
	_begin(3, func(c: MatchConfig) -> void:
		c.mode = MatchConfig.Mode.FREE_FOR_ALL
		c.win_condition = MatchConfig.WinCondition.TIME_ONLY
		c.kill_limit = 50
		c.time_limit = 10)
	MatchState.match_finished.connect(func(s: Dictionary) -> void:
		finished.merge(s, true), CONNECT_ONE_SHOT)

	_kill(901, 902)
	_check("clock is running", MatchState.time_left > 0.0, true)
	MatchState._tick_clock(9.0)
	_check("still playing with a second left", MatchState.phase, MatchState.Phase.PLAYING)
	MatchState._tick_clock(2.0)
	_check("clock stops at zero", MatchState.time_left, 0.0)
	_check("finished on time", MatchState.phase, MatchState.Phase.POST_MATCH)
	_check("reason", finished.get("reason"), "time")
	_check("the leader wins on points", _leader(finished), 902)


func _run_void_credit() -> void:
	_scenario("falling off the island")
	_begin(3, func(c: MatchConfig) -> void:
		c.mode = MatchConfig.Mode.FREE_FOR_ALL
		c.win_condition = MatchConfig.WinCondition.KILL_LIMIT
		c.kill_limit = 50
		c.time_limit = 0)

	# Nobody touched them: the fall is their own doing, and costs them a death
	# without paying anyone.
	MatchState.report_kill(901, 901, Gub.Cause.VOID, Vector3.ZERO, Vector3.DOWN, "")
	_check("a fall costs a death", MatchState.deaths(901), 1)
	_check("and pays nobody", MatchState.kills(901), 0)
	_revive(901)

	# Lured off the edge: `note_attack` is what carries the credit across.
	MatchState.note_attack(901, 902)
	MatchState.report_kill(901, 902, Gub.Cause.VOID, Vector3.ZERO, Vector3.DOWN, "")
	_check("the lurer is credited", MatchState.kills(902), 1)


func _run_spawn_protection() -> void:
	_scenario("spawn protection")
	_begin(3, func(c: MatchConfig) -> void:
		c.mode = MatchConfig.Mode.FREE_FOR_ALL
		c.win_condition = MatchConfig.WinCondition.KILL_LIMIT
		c.kill_limit = 50
		c.time_limit = 0
		c.spawn_protection = 5.0)

	# A Gub that has just spawned is solid but unkillable, so spawning face to
	# face with someone holding a spear is survivable.
	var victim: Gub = MatchState.gubs.get(901)
	_check("a Gub exists to protect", is_instance_valid(victim), true)
	_check("and starts protected", victim.is_invulnerable(), true)
	_kill(901, 1)
	_check("a spear cannot kill it", MatchState.is_alive(901), true)
	_check("and earns nothing", MatchState.kills(1), 0)

	# Falling off the island is not something protection should save you from,
	# or a protected Gub could sit in the void forever.
	MatchState.report_kill(901, 901, Gub.Cause.VOID, Vector3.ZERO, Vector3.DOWN, "")
	_check("but the void still takes it", MatchState.is_alive(901), false)

	# Once protection lapses the same spear lands.
	_revive(901)
	victim.invulnerable_until = 0.0
	_kill(901, 1)
	_check("and it dies once protection lapses", MatchState.is_alive(901), false)
	_check("paying the killer", MatchState.kills(1), 1)


func _run_config_validation() -> void:
	_scenario("config arriving off the wire")
	# `apply_dict` is the deserialiser for host-controlled match settings, so
	# everything it reads is attacker-controlled on a client. It is the one
	# place in this codebase where a hostile peer gets to set a value directly,
	# which is why it clamps rather than trusts — see the header of
	# match_config.gd for why a Dictionary crosses the wire and not a Resource.
	var config := MatchConfig.new()

	config.apply_dict({"kill_limit": 9999, "lives": -40, "team_count": 500})
	_check("an absurd kill limit is clamped", config.kill_limit, 50)
	_check("a negative life count is clamped", config.lives, 1)
	_check("team count is clamped", config.team_count, 8)

	# An out-of-range enum would index past the end of whatever switches on it.
	config.apply_dict({"mode": 9999, "win_condition": -3})
	_check("mode stays a real mode", config.mode, MatchConfig.Mode.TEAMS)
	_check("win condition stays real", config.win_condition,
		MatchConfig.WinCondition.KILL_LIMIT)

	# Wrong types are dropped, not coerced into nonsense.
	var before := config.spear_recharge
	config.apply_dict({"spear_recharge": "very fast", "friendly_fire": "yes"})
	_check("a string cannot become a float", config.spear_recharge, before)
	_check("a string cannot become a bool", config.friendly_fire, false)

	# Ints and floats are interchangeable often enough to be worth coercing.
	config.apply_dict({"spear_recharge": 4})
	_check("an int becomes a float", config.spear_recharge, 4.0)

	config.apply_dict({"not_a_field": 12, "kill_limit": 7})
	_check("unknown keys are ignored", config.kill_limit, 7)

	var kept := config.lives
	config.apply_dict({"kill_limit": 8})
	_check("missing keys keep their value", config.lives, kept)

	# A timed match with no clock would never end.
	config.apply_dict({"win_condition": MatchConfig.WinCondition.TIME_ONLY,
		"time_limit": 0})
	_check("a timed match gets a clock", config.time_limit > 0, true)

	# Regression guard: lure_fuse defaulted to 0.35 while its own range started
	# at 0.5, so every fresh config was silently raised and the declared default
	# was never the value anyone played with.
	var fresh := MatchConfig.new()
	var default_fuse := fresh.lure_fuse
	fresh.apply_dict({})
	_check("every default survives its own clamp", fresh.lure_fuse, default_fuse)

	# Whatever a host sets must arrive unchanged at the far end.
	var host := MatchConfig.new()
	host.mode = MatchConfig.Mode.TEAMS
	host.kill_limit = 23
	host.friendly_fire = true
	host.map_seed = 987654
	host.lure_radius = 12.5
	var arrived := MatchConfig.new()
	arrived.apply_dict(host.to_dict())
	_check("mode survives the trip", arrived.mode, host.mode)
	_check("kill limit survives", arrived.kill_limit, host.kill_limit)
	_check("friendly fire survives", arrived.friendly_fire, host.friendly_fire)
	_check("the map seed survives", arrived.map_seed, host.map_seed)
	_check("floats survive", arrived.lure_radius, host.lure_radius)

	var copy := host.duplicate_config()
	_check("duplicate_config matches", copy.to_dict(), host.to_dict())
