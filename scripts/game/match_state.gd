extends Node
## Authoritative match lifecycle: who is alive, who killed whom, who is winning,
## and when it ends. Autoloaded as `MatchState`.
##
## `Net` owns the roster (who is connected and what they are called). This owns
## everything that only exists once a match is running. Keeping them apart means
## a disconnect is handled in exactly one place, and the lobby can be exercised
## with none of this loaded.
##
## Everything here is host-authoritative. Clients receive results and display
## them; they never decide a kill, a respawn or a score. The one thing clients
## do own is their own Gub's movement (docs/DECISIONS.md D-004), which is why
## respawning teleports via an RPC to the owner rather than by the host setting
## a position it does not control.

signal phase_changed(phase: Phase)
signal scores_changed()
signal player_killed(victim_id: int, killer_id: int, cause: int)
signal clock_changed(seconds_left: float)
signal match_finished(summary: Dictionary)
signal local_death(respawn_in: float)
signal local_respawn()

enum Phase { IDLE, WARMUP, PLAYING, POST_MATCH }

const GUB_SCENE := preload("res://scenes/player/gub.tscn")

## Anything below this has left the island and is not coming back.
const VOID_HEIGHT := -45.0
## A fall that ends in the void still counts as a death, but the kill is only
## credited to another player if they were the last to touch you this recently.
const ASSIST_WINDOW := 4.0

var phase: Phase = Phase.IDLE
var time_left: float = 0.0

## peer_id -> {kills, deaths, lives_left, alive, respawn_at, last_attacker,
##             last_attacker_at}
var stats: Dictionary = {}
## peer_id -> Gub
var gubs: Dictionary = {}

var _players_root: Node = null
var _spawn_points: Array[Transform3D] = []
var _spawn_cursor: int = 0
var _phase_timer: float = 0.0
var _finished: bool = false


func _ready() -> void:
	Net.left_lobby.connect(_on_left_lobby)


func config() -> MatchConfig:
	return Net.config


func _now() -> float:
	return Time.get_ticks_msec() * 0.001


# ------------------------------------------------------------------- arena ---

## Called by the arena once its geometry and spawn points exist. Every peer does
## this for itself; only the host acts on it.
func register_arena(players_root: Node, spawn_points: Array[Transform3D]) -> void:
	_players_root = players_root
	_spawn_points = spawn_points
	# Deterministic but not identical between matches, so the same person does
	# not always open on the same ledge.
	var rng := RandomNumberGenerator.new()
	rng.seed = config().map_seed
	_spawn_cursor = rng.randi_range(0, maxi(1, _spawn_points.size()) - 1)

	if Net.is_host:
		_begin_warmup()


func _on_left_lobby(_reason: int, _message: String) -> void:
	reset()


func reset() -> void:
	for gub: Gub in gubs.values():
		if is_instance_valid(gub):
			gub.queue_free()
	gubs.clear()
	stats.clear()
	_finished = false
	time_left = 0.0
	_set_phase(Phase.IDLE)


# ------------------------------------------------------------------ phases ---

func _set_phase(next: Phase) -> void:
	if phase == next:
		return
	phase = next
	phase_changed.emit(phase)


func _begin_warmup() -> void:
	stats.clear()
	for peer_id: int in Net.peer_ids():
		stats[peer_id] = _new_stats()
	_finished = false
	time_left = float(config().time_limit)
	_phase_timer = config().warmup_time

	_sync_phase.rpc(Phase.WARMUP, _phase_timer, time_left)
	_sync_phase(Phase.WARMUP, _phase_timer, time_left)
	for peer_id: int in Net.peer_ids():
		_spawn_gub(peer_id)
	_push_scores()


func _new_stats() -> Dictionary:
	return {
		"kills": 0,
		"deaths": 0,
		"lives_left": config().lives,
		"alive": true,
		"respawn_at": 0.0,
		"last_attacker": 0,
		"last_attacker_at": -999.0,
	}


@rpc("authority", "call_remote", "reliable")
func _sync_phase(next: Phase, phase_seconds: float, clock: float) -> void:
	_phase_timer = phase_seconds
	time_left = clock
	_set_phase(next)
	clock_changed.emit(time_left)


func _process(delta: float) -> void:
	if not Net.is_host or phase == Phase.IDLE:
		return

	if phase == Phase.WARMUP:
		_phase_timer -= delta
		if _phase_timer <= 0.0:
			_sync_phase.rpc(Phase.PLAYING, 0.0, time_left)
			_sync_phase(Phase.PLAYING, 0.0, time_left)
		return

	if phase != Phase.PLAYING:
		return

	_tick_clock(delta)
	_tick_respawns()
	_tick_void()


func _tick_clock(delta: float) -> void:
	if config().time_limit <= 0:
		return
	time_left = maxf(0.0, time_left - delta)
	# Broadcast about once a second rather than every frame; the clock is a
	# display, and everyone counts down locally between updates.
	if int(time_left * 2.0) != int((time_left + delta) * 2.0):
		_sync_clock.rpc(time_left)
		clock_changed.emit(time_left)
	if time_left <= 0.0:
		_finish("time")


@rpc("authority", "call_remote", "unreliable")
func _sync_clock(seconds: float) -> void:
	time_left = seconds
	clock_changed.emit(time_left)


func _tick_respawns() -> void:
	for peer_id: int in stats.keys():
		var entry: Dictionary = stats[peer_id]
		if entry["alive"] or entry["respawn_at"] <= 0.0:
			continue
		if _now() < entry["respawn_at"]:
			continue
		if config().win_condition == MatchConfig.WinCondition.LIVES \
				and entry["lives_left"] <= 0:
			entry["respawn_at"] = 0.0  # eliminated; spectating
			continue
		_respawn(peer_id)


## Falling off the island. Checked on the host for everyone, because a client
## that has fallen is often the one least able to report it.
func _tick_void() -> void:
	for peer_id: int in gubs.keys():
		var gub: Gub = gubs[peer_id]
		if not is_instance_valid(gub) or not gub.alive:
			continue
		if gub.global_position.y > VOID_HEIGHT:
			continue
		var entry: Dictionary = stats.get(peer_id, {})
		# If someone lured or spooked you off the edge moments ago, they get it.
		var attacker: int = entry.get("last_attacker", 0)
		var recent: bool = _now() - float(entry.get("last_attacker_at", -999.0)) < ASSIST_WINDOW
		report_kill(peer_id, attacker if recent else peer_id, Gub.Cause.VOID,
			gub.global_position, Vector3.DOWN, "")


# ------------------------------------------------------------------ spawns ---

func _next_spawn() -> Transform3D:
	if _spawn_points.is_empty():
		return Transform3D.IDENTITY
	# Walk the list rather than picking at random, so two Gubs cannot land on
	# the same pad on the same frame.
	var best := _spawn_points[_spawn_cursor % _spawn_points.size()]
	_spawn_cursor += 1

	# Prefer a pad with nobody standing near it. Spawning face to face with an
	# armed Gub is the cheapest death in the game.
	var safest := best
	var safest_distance := -1.0
	for i in _spawn_points.size():
		var candidate := _spawn_points[(_spawn_cursor + i) % _spawn_points.size()]
		var nearest := INF
		for gub: Gub in gubs.values():
			if is_instance_valid(gub) and gub.alive:
				nearest = minf(nearest, candidate.origin.distance_to(gub.global_position))
		if nearest > safest_distance:
			safest_distance = nearest
			safest = candidate
		if nearest > 18.0:
			break
	return safest


func _spawn_gub(peer_id: int) -> void:
	var spawn := _next_spawn()
	_create_gub.rpc(peer_id, spawn)
	_create_gub(peer_id, spawn)


@rpc("authority", "call_remote", "reliable")
func _create_gub(peer_id: int, spawn: Transform3D) -> void:
	if _players_root == null or gubs.has(peer_id):
		return
	var gub := GUB_SCENE.instantiate() as Gub
	gub.name = "Gub_%d" % peer_id
	gub.peer_id = peer_id
	gub.display_name = Net.player_name(peer_id)
	gub.team = Net.player_team(peer_id)
	_players_root.add_child(gub)
	# Ownership has to be set after the node is in the tree, or the
	# MultiplayerSynchronizer under it starts out pointed at the wrong peer.
	gub.set_multiplayer_authority(peer_id)
	gub.global_transform = spawn
	gub.body_yaw = spawn.basis.get_euler().y
	gub.grant_invulnerability(config().spawn_protection)

	var plate := gub.get_node_or_null("Nameplate") as Nameplate
	if plate != null:
		plate.set_display_name(gub.display_name)
		plate.set_team(gub.team if config().mode == MatchConfig.Mode.TEAMS
			else MatchConfig.TEAM_NONE)
		# You do not need a label telling you your own name.
		plate.visible = peer_id != multiplayer.get_unique_id()

	gubs[peer_id] = gub
	if not stats.has(peer_id):
		stats[peer_id] = _new_stats()


func _respawn(peer_id: int) -> void:
	var spawn := _next_spawn()
	var entry: Dictionary = stats[peer_id]
	entry["alive"] = true
	entry["respawn_at"] = 0.0
	entry["last_attacker"] = 0
	_do_respawn.rpc(peer_id, spawn)
	_do_respawn(peer_id, spawn)
	_push_scores()


@rpc("authority", "call_remote", "reliable")
func _do_respawn(peer_id: int, spawn: Transform3D) -> void:
	var gub: Gub = gubs.get(peer_id)
	if not is_instance_valid(gub):
		return
	gub.visible = true
	gub.revive_at(spawn)
	gub.grant_invulnerability(config().spawn_protection)
	var combat := gub.get_node_or_null("Combat") as GubCombat
	if combat != null:
		combat.reset()
	if peer_id == multiplayer.get_unique_id():
		local_respawn.emit()


# ------------------------------------------------------------------- kills ---

## Host only. The single place a death is decided.
func report_kill(victim_id: int, killer_id: int, cause: Gub.Cause,
		point: Vector3, direction: Vector3, bone: String) -> void:
	if not Net.is_host or phase != Phase.PLAYING:
		return
	var entry: Dictionary = stats.get(victim_id, {})
	if entry.is_empty() or not entry["alive"]:
		return

	var victim: Gub = gubs.get(victim_id)
	if is_instance_valid(victim) and victim.is_invulnerable() and cause != Gub.Cause.VOID:
		return

	# Friendly fire is off by default, so a team-mate's spear simply stops.
	if killer_id != victim_id and _same_team(killer_id, victim_id) \
			and not config().friendly_fire:
		return

	entry["alive"] = false
	entry["deaths"] += 1
	entry["respawn_at"] = _now() + config().respawn_delay
	if config().win_condition == MatchConfig.WinCondition.LIVES:
		entry["lives_left"] = maxi(0, entry["lives_left"] - 1)

	if killer_id != victim_id and stats.has(killer_id):
		# Killing a team-mate costs you the point rather than earning one.
		var delta := -1 if _same_team(killer_id, victim_id) else 1
		stats[killer_id]["kills"] += delta

	_apply_death.rpc(victim_id, killer_id, cause, point, direction, bone)
	_apply_death(victim_id, killer_id, cause, point, direction, bone)
	_push_scores()
	_check_win()


@rpc("authority", "call_remote", "reliable")
func _apply_death(victim_id: int, killer_id: int, cause: Gub.Cause,
		point: Vector3, direction: Vector3, bone: String) -> void:
	var victim: Gub = gubs.get(victim_id)
	if is_instance_valid(victim):
		victim.kill(killer_id, cause)
		# The corpse is a separate, local, cosmetic thing (D-010).
		if cause != Gub.Cause.VOID:
			GubRagdoll.spawn_from(victim, victim.get_parent(),
				direction * 2.6 + Vector3.UP * 0.5, bone)
		victim.visible = false

	player_killed.emit(victim_id, killer_id, cause)
	if victim_id == multiplayer.get_unique_id():
		local_death.emit(config().respawn_delay)
		var rig := victim.get_node_or_null("CameraRig") as GubCamera if is_instance_valid(victim) else null
		if rig != null:
			rig.shake(1.4)
	elif killer_id == multiplayer.get_unique_id():
		var killer: Gub = gubs.get(killer_id)
		if is_instance_valid(killer):
			var rig2 := killer.get_node_or_null("CameraRig") as GubCamera
			if rig2 != null:
				rig2.shake(0.35)


## Note that `attacker` hurt `victim` without killing them, so a subsequent fall
## into the void can still be credited. Host only.
func note_attack(victim_id: int, attacker_id: int) -> void:
	if not Net.is_host or not stats.has(victim_id):
		return
	stats[victim_id]["last_attacker"] = attacker_id
	stats[victim_id]["last_attacker_at"] = _now()


func _same_team(a: int, b: int) -> bool:
	if config().mode != MatchConfig.Mode.TEAMS:
		return false
	return Net.player_team(a) == Net.player_team(b)


# ------------------------------------------------------------------ scores ---

func _push_scores() -> void:
	_sync_scores.rpc(stats)
	scores_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _sync_scores(incoming: Dictionary) -> void:
	stats = incoming
	scores_changed.emit()


func kills(peer_id: int) -> int:
	return stats.get(peer_id, {}).get("kills", 0)


func deaths(peer_id: int) -> int:
	return stats.get(peer_id, {}).get("deaths", 0)


func lives_left(peer_id: int) -> int:
	return stats.get(peer_id, {}).get("lives_left", 0)


func is_alive(peer_id: int) -> bool:
	return stats.get(peer_id, {}).get("alive", false)


func team_score(team: int) -> int:
	var total := 0
	for peer_id: int in stats:
		if Net.player_team(peer_id) == team:
			total += kills(peer_id)
	return total


## Peers sorted best-first, for the scoreboard and the results screen.
func ranking() -> Array:
	var ids := stats.keys()
	ids.sort_custom(func(a, b):
		if kills(a) != kills(b):
			return kills(a) > kills(b)
		return deaths(a) < deaths(b))
	return ids


# ---------------------------------------------------------------- win check ---

func _check_win() -> void:
	match config().win_condition:
		MatchConfig.WinCondition.KILL_LIMIT:
			for peer_id: int in stats:
				if _score_for(peer_id) >= config().kill_limit:
					_finish("limit")
					return
		MatchConfig.WinCondition.LIVES:
			var standing := _still_standing()
			if standing.size() <= 1 and stats.size() > 1:
				_finish("elimination")
		MatchConfig.WinCondition.TIME_ONLY:
			pass


## In teams, a kill counts toward the team's total, so the limit is a team limit.
func _score_for(peer_id: int) -> int:
	if config().mode == MatchConfig.Mode.TEAMS:
		return team_score(Net.player_team(peer_id))
	return kills(peer_id)


func _still_standing() -> Array:
	var out := []
	for peer_id: int in stats:
		if stats[peer_id]["lives_left"] > 0 or stats[peer_id]["alive"]:
			out.append(peer_id)
	return out


func _finish(reason: String) -> void:
	if _finished:
		return
	_finished = true
	var summary := {
		"reason": reason,
		"ranking": ranking(),
		"stats": stats,
		"mode": config().mode,
	}
	if config().mode == MatchConfig.Mode.TEAMS:
		var scores := {}
		for team in config().team_count:
			scores[team] = team_score(team)
		summary["team_scores"] = scores

	_sync_phase.rpc(Phase.POST_MATCH, 0.0, time_left)
	_sync_phase(Phase.POST_MATCH, 0.0, time_left)
	_sync_finish.rpc(summary)
	_sync_finish(summary)


@rpc("authority", "call_remote", "reliable")
func _sync_finish(summary: Dictionary) -> void:
	_set_phase(Phase.POST_MATCH)
	match_finished.emit(summary)


## The Gub this client is driving, or null while dead or spectating.
func local_gub() -> Gub:
	var gub: Gub = gubs.get(multiplayer.get_unique_id())
	return gub if is_instance_valid(gub) else null
