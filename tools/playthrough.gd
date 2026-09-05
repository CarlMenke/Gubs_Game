extends Node
## Drives the whole game once, from the main menu to the results screen, and
## asserts something real at every stop. Development tool, not shipped. Runs
## headless in a handful of seconds.
##
##   Godot --headless --path . tools/playthrough.tscn
##
## Every other harness in this folder looks at one seam. `match_rules` scores a
## match that has no island under it, `combat_range` throws a spear in a room
## with no lobby in front of it, `ui_range` photographs screens that were never
## navigated to. Each of those was worth writing and none of them would notice
## if the menu stopped handing off to the lobby, if `request_match_start` never
## reached the arena, or if the results screen sat behind the HUD it is supposed
## to replace. Those are joins between parts, they are exactly where the bugs
## that survive a code review live, and until this file existed nothing had ever
## walked across all of them in one go.
##
## So this is the *whole* path, in order, through the real shipping scenes and
## the real autoloads:
##
##   main menu -> host -> lobby -> start -> arena builds -> warmup -> match
##   plays -> kill limit trips -> results screen
##
## The only things faked are the things that cannot exist on one machine: the
## session has no socket (`Net.start_offline`, D-011) and the other players are
## roster entries with nobody behind them. Everything else is the code that
## ships. Nothing here reaches past a public API except where a comment says
## otherwise and why.
##
## Like `tools/match_rules.gd`, this runs as a *scene* rather than as a
## `--script` main loop: a script main loop is compiled before the autoloads are
## registered, so it cannot so much as name `Net` or `MatchState` without
## failing to parse (D-015).

## Peer ids for the stand-in players. ENet hands out ids at random across the
## whole positive int range, so no band is truly safe; what these have to avoid
## is the *other* harnesses, since a shared id would make two testbeds
## impossible to tell apart in a log. `ui_range` owns the 700s, `combat_range`
## the 900s, `GubBackdrop` the 8100s. This takes the 500s.
const FAKE_BASE := 500

## The stand-ins. The first of them does all the killing and therefore wins, so
## the winner's name is a fixed, known string — the *local* player's name is
## whatever was last typed into a name box and persisted into Godot's user-data
## directory, which is shared by every checkout of this project, so it cannot be
## asserted on. (`tools/smoke_test.sh` learned the same lesson about the killer
## name in the combat range.)
const FAKE_NAMES := ["Pipwick", "Thistle", "Mossback", "Bramblewick"]

## Warmup is shortened from the shipping default of five seconds. It is not
## skipped: the point is to watch the phase actually pass through WARMUP on its
## way to PLAYING, which is the transition the HUD's opening countdown hangs off.
const WARMUP_TIME := 0.5
## Spawn protection off, respawn delay to nothing. Both are deliberate and both
## are set the way a host sets them — through `Net.update_config`. Protection in
## particular has to go: it defaults to two seconds, a protected Gub correctly
## refuses to die, and leaving it on simply makes the kill loop spin until it
## gives up. That cost an hour in `match_rules` and the note is repeated here
## because the symptom (scoring looks broken) points nowhere near the cause.
const SPAWN_PROTECTION := 0.0
const RESPAWN_DELAY := 0.0

## Wall-clock budgets. Generous, because they exist to turn a hang into a
## legible failure rather than to measure anything.
const SCENE_TIMEOUT := 30.0
## The island build is 2-6 seconds of blocking work inside `arena.gd::_ready`,
## and a cold import or a loaded machine can make that a good deal worse. This
## is the one wait that must never be a fixed frame count.
const ARENA_TIMEOUT := 120.0
const PHASE_TIMEOUT := 30.0
const KILL_TIMEOUT := 60.0

## The shipping script whose row eviction decides whether a match can survive
## six deaths. See `_kill_feed_hazard`.
const KILL_FEED_SCRIPT := "res://scripts/ui/kill_feed.gd"

var _checks: int = 0
var _failures: int = 0
## Every phase `MatchState` announced, in order. Recorded from the signal rather
## than sampled per frame: the frame straight after a three-second island build
## carries a three-second delta, which is long enough for WARMUP to open and
## close between two of our own looks at it.
var _phases: Array[int] = []
## The summary `match_finished` carried, captured the way the results screen
## captures it.
var _summary: Dictionary = {}
## The last path `SceneFlow` finished a transition to.
##
## This is *not* the same thing as "the scene is in the tree", and the
## difference cost an afternoon. `SceneFlow.go_to` swaps the scene, then spends
## another 0.3 s fading back in, and refuses a second transition for the whole
## of that window. So a harness that notices the lobby the moment
## `current_scene` changes and immediately presses Start gets a
## `go_to_arena()` that returns without doing anything, and then waits two
## minutes for an arena that was never asked for. Waiting on `scene_ready` —
## which is emitted after the fade, with the busy flag already cleared — is
## waiting for the same moment a player would have pressed the button in.
var _scene_ready_path: String = ""


func _ready() -> void:
	print("playthrough: starting")
	# Cap the loop to the physics rate, exactly as `tools/snapshot.gd` does and
	# for a sharper version of the same reason (D-012).
	#
	# Headless has no vsync, so the loop free-runs at several thousand frames a
	# second, and a corpse does not survive that. Run `ragdoll_stability.tscn`
	# uncapped headless and it FAILs: bodies still moving at 71 m/s when they
	# should be at rest, having peaked at 119. Run the same scene with the rate
	# pinned and it settles at 0.06 m/s and passes. This harness kills fifteen
	# Gubs, so it would be building fifteen of those. Capping is not tidiness
	# here, it is the difference between simulating the game and simulating a
	# different game that happens to share its code.
	Engine.max_fps = int(ProjectSettings.get_setting(
		"physics/common/physics_ticks_per_second", 60))
	# Step out of the current-scene slot before anything calls
	# `change_scene_to_file`. `SceneTree` frees whatever is sitting in that slot
	# when the scene changes, and this harness has to outlive every screen it
	# drives — without this line the first transition, menu to lobby, deletes
	# the thing doing the driving and the run ends in silence rather than in a
	# failure. The node stays a child of `root` either way; only the pointer
	# that marks it as "the scene" is cleared.
	get_tree().current_scene = null

	SceneFlow.scene_ready.connect(func(path: String) -> void: _scene_ready_path = path)
	MatchState.phase_changed.connect(func(phase: int) -> void: _phases.append(phase))
	MatchState.match_finished.connect(func(summary: Dictionary) -> void:
		_summary = summary.duplicate(true), CONNECT_ONE_SHOT)

	# Each stage returns false when it could not reach the next one, and the run
	# stops there. Carrying on past a missing lobby would only produce a page of
	# consequential failures with the real one at the top.
	var ok := await _stage_menu()
	if ok:
		ok = await _stage_host()
	if ok:
		ok = await _stage_lobby()
	if ok:
		ok = await _stage_arena()
	if ok:
		ok = await _stage_warmup()
	if ok:
		ok = await _stage_match()
	if ok:
		ok = await _stage_results()

	print("playthrough: %d checks, %d failures" % [_checks, _failures])
	print("playthrough: %s" % ("PASS" if _failures == 0 else "FAIL"))
	await _teardown()
	get_tree().quit(1 if _failures > 0 else 0)


# ------------------------------------------------------------------ stages ---

## The first screen anyone sees, loaded through the same `SceneFlow` call the
## game boots with rather than by hand, so the fade and the scene swap are the
## ones that ship.
func _stage_menu() -> bool:
	await SceneFlow.go_to_menu()
	if not _require("the menu is the current scene",
			_scene_path() == SceneFlow.MENU):
		return false
	# Not just "a scene loaded": the menu without its Host button is a menu
	# nobody can leave, and a renamed unique node would sail past a path check.
	var menu := get_tree().current_scene
	if not _require("the menu has a Host button",
			menu.get_node_or_null("%HostButton") is Button):
		return false
	print("playthrough: menu ok")
	return true


## Host. `Net.start_offline()` opens a real session with no socket — peer 1,
## `is_server()` true, every `is_host` branch and every `@rpc` downstream taking
## exactly the path it takes when hosting for real (D-011). The Host button
## itself calls `Net.host_lobby`, which binds a port; a test that opens a
## listening socket is a test that fails on a machine already running the game,
## and worse, one that raises a firewall prompt in CI.
##
## Everything after the session opening is the real button path: `start_offline`
## emits `joined_lobby`, the menu is listening, and the menu is what calls
## `SceneFlow.go_to_lobby()`. That handoff is one of the joins this file exists
## to watch, so it is deliberately not short-circuited here.
func _stage_host() -> bool:
	Net.start_offline()
	if not _require("the session is open", Net.in_session):
		return false
	_check("the local peer is the host", Net.is_host, true)
	_check("the local peer is 1", Net.local_id(), 1)

	# Stand-ins written straight into the roster, exactly as `ui_range` does.
	# `MatchState` spawns a Gub for each without ever asking whether there is a
	# client behind one, so these become remote Gubs to this peer.
	for i in FAKE_NAMES.size():
		Net.players[FAKE_BASE + i] = {
			"name": FAKE_NAMES[i], "team": 0, "ready": true,
		}
	Net.roster_changed.emit()

	# Match settings are pushed the way the lobby's settings panel pushes them,
	# rather than by poking `Net.config`: `update_config` is the host-side API,
	# it re-clamps everything on the way in, and using it means this harness
	# also proves that path still works.
	var settings := Net.config.duplicate_config()
	settings.warmup_time = WARMUP_TIME
	settings.spawn_protection = SPAWN_PROTECTION
	settings.respawn_delay = RESPAWN_DELAY
	Net.update_config(settings)
	_check("warmup was shortened", Net.config.warmup_time, WARMUP_TIME)

	print("playthrough: session ok (offline host, peer 1, %d players, seed %d)" % [
		Net.player_count(), Net.config.map_seed])
	return true


## The lobby, arrived at by the menu's own `joined_lobby` handler.
func _stage_lobby() -> bool:
	if not await _await_until("the lobby scene", SCENE_TIMEOUT,
			func() -> bool: return _scene_ready_path == SceneFlow.LOBBY):
		return false
	if not _require("the lobby is the current scene",
			_scene_path() == SceneFlow.LOBBY):
		return false
	var lobby := get_tree().current_scene
	# The roster the lobby *drew*, not the one `Net` holds. Reading the label is
	# the only way to tell "the lobby is showing the five people who are here"
	# from "the lobby loaded and rendered an empty room", which is precisely the
	# failure D-015 was written about.
	var count_label := lobby.get_node_or_null("%PlayerCount") as Label
	if not _require("the lobby has its player count", count_label != null):
		return false
	_check("the lobby drew the whole roster", count_label.text,
		"%d / %d" % [Net.player_count(), Net.config.max_players])
	# Aborting rather than merely counting this one: `request_match_start`
	# silently does nothing when the gate is shut, and the next stage would then
	# spend two minutes waiting for an arena nobody asked for.
	if not _require("the host may start", Net.can_start_match()):
		return false
	print("playthrough: lobby ok (%d players, host can start)" % Net.player_count())
	return true


## Start the match and wait for the island. `request_match_start` emits
## `match_start_requested`; the lobby is listening and calls
## `SceneFlow.go_to_arena()`, which is the second join this file exists to watch.
func _stage_arena() -> bool:
	_scene_ready_path = ""
	var started := Time.get_ticks_msec()
	Net.request_match_start()
	if not _require("the match was accepted as started", Net.match_running):
		return false
	if not await _await_until("the arena scene",
			ARENA_TIMEOUT, func() -> bool: return get_tree().current_scene is Arena):
		return false
	var elapsed := Time.get_ticks_msec() - started

	var arena := get_tree().current_scene as Arena
	_check("the arena laid out its spawn ring", arena.spawn_points.size(),
		Arena.SPAWN_COUNT)
	# A spawn point at the origin is the shape `_solve_spawn` fails into, and
	# every Gub standing on the same pad is a spawn ring that never ran.
	var distinct := {}
	for spawn: Transform3D in arena.spawn_points:
		distinct[spawn.origin.snapped(Vector3.ONE * 0.01)] = true
	_check("the spawn pads are in different places", distinct.size(),
		arena.spawn_points.size())

	# Gubs are the proof that `register_arena` actually happened: nothing else
	# spawns them, and an arena that builds beautifully and never hands over is
	# a black screen with a nice island in it.
	_check("a Gub exists for every player", MatchState.gubs.size(),
		Net.player_count())
	for peer_id: int in Net.peer_ids():
		var gub: Gub = MatchState.gubs.get(peer_id)
		if not _require("peer %d has a Gub in the tree" % peer_id,
				is_instance_valid(gub) and gub.is_inside_tree()):
			return false

	# The arena instances the HUD itself, and every match before that wiring
	# existed ran with no crosshair, no score and no way to open the pause menu.
	if not _require("the arena instanced the HUD", _find_hud() != null):
		return false

	print("playthrough: arena built in %d ms, %d spawns, %d gubs" % [
		elapsed, arena.spawn_points.size(), MatchState.gubs.size()])
	return true


## Warmup, waited out rather than skipped, because the phase machine only ever
## reaches PLAYING through it.
func _stage_warmup() -> bool:
	var started := Time.get_ticks_msec()
	if not await _await_until("phase PLAYING", PHASE_TIMEOUT,
			func() -> bool: return MatchState.phase == MatchState.Phase.PLAYING):
		return false
	_check("the match warmed up before it played",
		_phases.has(MatchState.Phase.WARMUP), true)
	_check("WARMUP came before PLAYING",
		_phases.find(MatchState.Phase.WARMUP) < _phases.find(MatchState.Phase.PLAYING),
		true)
	print("playthrough: phase PLAYING after %.1f s" % [
		float(Time.get_ticks_msec() - started) * 0.001])
	return true


## Play the match out. Kills go through `MatchState.report_kill`, which is
## host-only and is the single place a death is decided — the same call the
## spear makes when it lands, and the same one `match_rules` drives.
##
## One kill per frame, with the frame in between doing the work: the host's
## `_process` runs `_tick_respawns`, which is what brings the victim back. So
## this is not a bare scoring loop — every swing is a whole death-and-respawn
## cycle through `_apply_death`, `GubRagdoll.spawn_from` and `_do_respawn`, and
## the match takes the kill limit's worth of them to end.
func _stage_match() -> bool:
	var killer := FAKE_BASE
	# The local player is in the rotation on purpose: dying is the only way to
	# reach `local_death`, and with it the HUD's respawn banner.
	var victims: Array[int] = [1, FAKE_BASE + 1, FAKE_BASE + 2, FAKE_BASE + 3]
	var limit := Net.config.kill_limit
	var respawned := 0
	var swing := 0
	var deaths := 0
	# Room for a refused kill or two without letting a stuck loop run forever.
	var max_swings := limit * 4 + 40
	var deadline := Time.get_ticks_msec() + int(KILL_TIMEOUT * 1000.0)
	# How many deaths this build can be asked for before the HUD wedges. Normally
	# there is no such number.
	var hazard := _kill_feed_hazard()
	var budget := KillFeed.MAX_ROWS if not hazard.is_empty() else max_swings

	while MatchState.phase == MatchState.Phase.PLAYING and swing < max_swings:
		if Time.get_ticks_msec() > deadline or deaths >= budget:
			break
		var victim: int = victims[swing % victims.size()]
		swing += 1
		if not MatchState.is_alive(victim):
			await get_tree().process_frame
			continue
		var gub: Gub = MatchState.gubs.get(victim)
		var point := gub.global_position if is_instance_valid(gub) else Vector3.ZERO
		# A blow with real speed in it, not a unit vector: the corpse's flight is
		# scaled by it, so a zero-length one would leave the ragdoll path
		# exercised but never actually pushed.
		MatchState.report_kill(victim, killer, Gub.Cause.SPEAR,
			point, Vector3.FORWARD * 18.0, "spine.002")
		deaths += 1
		await get_tree().process_frame
		if MatchState.is_alive(victim):
			respawned += 1

	if deaths >= budget and not hazard.is_empty():
		_checks += 1
		_failures += 1
		print("  FAIL  %s" % hazard)
		print("playthrough: stopped after %d deaths; %d kills scored, %d respawns" % [
			deaths, MatchState.kills(killer), respawned])
		return false

	_check("the killer reached the limit", MatchState.kills(killer), limit)
	_check("the dead came back", respawned > 0, true)
	if not _require("the match ended",
			MatchState.phase == MatchState.Phase.POST_MATCH):
		return false
	if not _require("match_finished carried a summary", not _summary.is_empty()):
		return false
	_check("the reason", _summary.get("reason"), "limit")
	var ranking: Array = _summary.get("ranking", [])
	if not _require("the summary has a ranking", not ranking.is_empty()):
		return false
	_check("the winner leads the ranking", int(ranking[0]), killer)
	_check("everyone is in the ranking", ranking.size(), Net.player_count())
	# A kill after the whistle must not count, here as in `match_rules` — this
	# is the one place it can be checked with a real Gub on the far end.
	MatchState.report_kill(victims[0], killer, Gub.Cause.SPEAR,
		Vector3.ZERO, Vector3.FORWARD, "spine.002")
	_check("no scoring after the match ends", MatchState.kills(killer), limit)

	print("playthrough: match finished — reason \"%s\", winner %s" % [
		_summary.get("reason", "?"), Net.player_name(int(ranking[0]))])
	return true


## The results screen. It is not a scene change — `hud.gd` instances
## `results_screen.tscn` as part of itself and reveals it from
## `_on_match_finished` — so this is a search of the live arena tree rather than
## a path check.
func _stage_results() -> bool:
	var hud := _find_hud()
	if not _require("the HUD is still in the tree", hud != null):
		return false
	var results := _find_first(hud, func(node: Node) -> bool: return node is ResultsScreen)
	if not _require("the HUD carries a results screen", results != null):
		return false
	var screen := results as ResultsScreen
	if not await _await_until("the results screen to open", SCENE_TIMEOUT,
			func() -> bool: return screen.visible):
		return false

	# One row per player, filled from the summary rather than from live state.
	var rows := screen.get_node_or_null("%Rows") as Container
	if not _require("the results screen has a table", rows != null):
		return false
	_check("a row per player", rows.get_child_count(),
		(_summary.get("ranking", []) as Array).size())

	var headline := screen.get_node_or_null("%Headline") as Label
	if not _require("the results screen has a headline", headline != null):
		return false
	var winner := Net.player_name(int((_summary.get("ranking", []) as Array)[0]))
	_check("the headline names the winner", headline.text.contains(winner), true)
	_check("the headline explains why it ended",
		(screen.get_node_or_null("%Subtitle") as Label).text,
		"The kill limit was reached.")

	# The gameplay HUD gets out of the way rather than sitting behind the table.
	var hud_root := hud.get_node_or_null("Root") as Control
	_check("the gameplay HUD stood down", hud_root != null and not hud_root.visible,
		true)

	print("playthrough: results ok (%d rows, headline \"%s\")" % [
		rows.get_child_count(), headline.text])
	return true


# ------------------------------------------------------------------ hazard ---

## Empty if this build can be asked for more deaths than the kill feed holds
## rows; otherwise the reason it cannot, ready to print.
##
## `KillFeed.add_kill` evicts its oldest row like this:
##
##     while get_child_count() > MAX_ROWS:
##         get_child(get_child_count() - 1).queue_free()
##
## `queue_free` does not remove the child. It schedules the deletion for the end
## of the frame, and the frame never ends, because the loop's condition is
## unchanged by it. So the *sixth* death in any match — MAX_ROWS is five — never
## returns from `report_kill`: the process pins a core at 100% and commits
## memory until something kills it. This harness found it on its first complete
## run, at exactly the sixth kill, having spent an afternoon looking for the
## fault in the ragdoll and the physics broadphase first, because the symptom is
## a hang and a runaway allocation rather than an error.
##
## The check has to be made against the *source*, which is not a thing a test
## should ever be pleased about. There is no alternative here: nothing can
## survive making that call, and from outside a fixed feed and a broken one are
## identical right up until the fatal row arrives. Rewriting the eviction so it
## removes the child before freeing it — two more lines — makes this return
## empty and the run carries straight on to the kill limit.
##
## Delete this function and its caller along with the bug.
func _kill_feed_hazard() -> String:
	var source := FileAccess.get_file_as_string(KILL_FEED_SCRIPT)
	if source.is_empty():
		return ""
	var at := source.find("while get_child_count() > MAX_ROWS:")
	if at < 0:
		return ""  # evicted some other way; nothing here can judge it
	# The body of that loop, generously bounded. A `remove_child` in it means
	# the child is gone before the next test of the condition, which is all the
	# loop needs to terminate.
	if source.substr(at, 240).contains("remove_child"):
		return ""
	return ("%s evicts rows with a bare queue_free() inside "
		+ "`while get_child_count() > MAX_ROWS`, which never terminates — the "
		+ "%dth death in any match hangs the process. Refusing to make the call. "
		+ "Fix: remove_child(oldest) before oldest.queue_free().") % [
			KILL_FEED_SCRIPT, KillFeed.MAX_ROWS + 1]


# ----------------------------------------------------------------- harness ---

## Free what the match left behind before quitting. Godot reports anything still
## alive at exit as a leak, and a harness that prints PASS above a wall of
## warnings teaches people to ignore warnings. A couple of dozen are reported
## regardless and always will be — they are the `preload` constants on the item
## and audio scripts, alive for as long as the scripts are, and `match_rules`
## carries the same note and the same tail of warnings.
##
## The session is deliberately *not* closed. `Net.leave_lobby` nulls the
## multiplayer peer, and every Gub still in the tree — the arena's, or the lobby
## backdrop's if the run stopped early — then calls `multiplayer.get_unique_id()`
## from `Gub.is_local()` on every frame of every `_process` it has, which buries
## the verdict under several hundred engine errors. Quitting is enough; the
## engine frees the tree on the way out.
func _teardown() -> void:
	MatchState.reset()
	for i in 4:
		await get_tree().process_frame


func _scene_path() -> String:
	var scene := get_tree().current_scene
	return scene.scene_file_path if scene != null else ""


## Spin frames until `ready` says yes. Wall clock rather than a frame count: the
## island build is one blocking frame of unknown length, so counting frames here
## would be counting the wrong thing entirely (D-012 makes the same point about
## the snapshot tool's warmup).
func _await_until(what: String, timeout: float, ready: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while not bool(ready.call()):
		if Time.get_ticks_msec() > deadline:
			_checks += 1
			_failures += 1
			print("  FAIL  timed out after %.0f s waiting for %s" % [timeout, what])
			return false
		await get_tree().process_frame
	return true


func _check(what: String, got: Variant, want: Variant) -> void:
	_checks += 1
	if got == want:
		return
	_failures += 1
	print("  FAIL  %s: got %s, wanted %s" % [what, str(got), str(want)])


## A check the rest of the run depends on. Same accounting, but the caller is
## expected to stop.
func _require(what: String, ok: bool) -> bool:
	_check(what, ok, true)
	return ok


func _find_hud() -> HUD:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	return _find_first(scene, func(node: Node) -> bool: return node is HUD) as HUD


## Depth-first search for the first node the predicate accepts. The HUD and the
## results screen are found this way rather than by path because both are
## instanced scenes whose unique-name (`%`) markers only resolve inside the
## scene that declares them.
func _find_first(from: Node, accepts: Callable) -> Node:
	if bool(accepts.call(from)):
		return from
	for child in from.get_children():
		var hit := _find_first(child, accepts)
		if hit != null:
			return hit
	return null
