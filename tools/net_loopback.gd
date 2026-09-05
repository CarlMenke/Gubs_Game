extends Node
## Two Godot processes, one real UDP socket, and the first packets this project
## has ever sent. Development tool, not shipped.
##
##     Godot --headless --path . tools/net_loopback.tscn -- host
##     Godot --headless --path . tools/net_loopback.tscn -- join K3M9P-2XQ7R
##
## `tools/net_test.sh` starts both halves and reduces them to one PASS/FAIL.
##
## Why this exists. Every other harness here — and every hour of play so far —
## runs through `Net.start_offline()`, which opens a session on an
## `OfflineMultiplayerPeer`: peer id 1, `is_server()` true, and **no socket**
## (D-011). That was the right call and it still is; it is also, precisely, a
## test that never sends anything. So the whole `rpc()`-then-call-locally
## pattern the codebase is built on has only ever run its second half. The
## serialization has never happened, `_request_join` has never been received,
## `_sync_roster` has never been decoded, `_unique_name` has never disambiguated
## a name that arrived over a wire, and `Net.player_left` has never fired for a
## peer that actually went away.
##
## This closes that gap on one machine over loopback. It is a *seam* test in
## D-015's sense, but the seam is the socket, and nothing else in the repo can
## stand on the far side of it.
##
## Shape of the run. The host drives; the client is reactive. They talk over two
## channels:
##
##   * the game's own messages — the thing under test,
##   * a control channel, `_ctl`, which is an `@rpc` on *this* node. Both
##     processes load the same scene, so the node sits at `/root/NetLoopback`
##     on both and can address itself. Borrowing `Net.send_chat` for the
##     coordination would have meant the chat check was proving the harness
##     rather than the game.
##
## Each side keeps its own tally and prints its own PASS/FAIL; the host also
## prints the client's, so one log tells the whole story.
##
## Like `tools/match_rules.gd` and `tools/playthrough.gd` this runs as a
## *scene*, not a `--script` main loop: a script main loop is compiled before
## the autoloads are registered, so it could not so much as name `Net` without
## failing to parse (D-015).
##
## Three things about running two copies of one project on one machine, all of
## which cost time to learn:
##
##   1. Godot's user data directory is keyed on the *project name*, not the
##      path, so both processes share `user://settings.cfg` and would otherwise
##      both join under whatever name was last typed into a name box. Names are
##      therefore set explicitly here — see `HOST_NAME` and `_run_client`.
##   2. Both processes will try to import assets into `.godot/` if they are
##      cold. `tools/net_test.sh` runs `--import` once before starting either.
##   3. On macOS, binding UDP 27015 can raise a firewall prompt the first time a
##      given binary does it. With the firewall off there is none. If a run
##      hangs with no `code=` line, look for a dialog.

## Dialled explicitly rather than through `Net.lan_invite_code()`. That helper
## encodes `Net.local_ipv4()`, which deliberately prefers a *private LAN*
## address (192.168.x, 10.x, carrier-private 172.16-31.x) so that the code it
## hands a player is the one that works with no setup. That is right for the
## game and wrong here: on a machine with Wi-Fi up it produces a code pointing
## at the LAN interface, which loops back through the network stack rather than
## through lo0 and fails outright on a machine with no network at all. The
## harness prints the LAN code too, so `InviteCode.encode` is still shown
## agreeing with `Net.lan_invite_code()` about everything but the address.
const LOOPBACK_IP := "127.0.0.1"

## Both sides ask for the same name on purpose: that is check 3. The host's is
## written straight into `Net.players`, the way `tools/ui_range.gd` and
## `tools/combat_range.gd` write their stand-ins — a public field, and the only
## way to name the host without persisting a name into the shared user data.
const HOST_NAME := "Gub"
## What the client asks `_request_join` to call it, and what the host must turn
## it into.
const CLIENT_NAME := "Gub"
const CLIENT_UNIQUE_NAME := "Gub (2)"

const CLIENT_CHAT := "client to host, over a socket"
const HOST_CHAT := "host to client, same socket"

## Config values pushed in check 4, chosen to be awkward rather than tidy.
## `map_seed` is past 2^32, so it proves an int survives as an int rather than
## as a truncated one. `lure_radius` is not representable in 32-bit float, which
## is the case Godot's variant encoder has to widen to 64 bits; `spear_recharge`
## is exactly representable, so the two together cover both branches.
const CONFIG_SEED := 4815162342
const CONFIG_KILL_LIMIT := 7
const CONFIG_LURE_RADIUS := 12.3
const CONFIG_SPEAR_RECHARGE := 4.25
## Short, but not skipped: PLAYING is only ever reached through WARMUP, and on
## the client it is reached through `_sync_phase` arriving over the wire.
const WARMUP_TIME := 1.0
## Off. A protected Gub correctly refuses to die, and leaving it on simply makes
## `report_kill` return without doing anything — a symptom that points nowhere
## near its cause. `tools/playthrough.gd` carries the same note.
const SPAWN_PROTECTION := 0.0

## Wall-clock budgets. Generous: they exist to turn a hang into a legible
## failure, not to measure anything.
const JOIN_TIMEOUT := 20.0
const STEP_TIMEOUT := 20.0
## The island build is 2-6 s of blocking work inside `arena.gd::_ready`, and
## here *two* processes do it at once on one machine.
const ARENA_TIMEOUT := 180.0
const PHASE_TIMEOUT := 60.0
## ENet notices a graceful `close()` almost immediately. A hard kill would leave
## it to the peer timeout instead, which is 5-30 s.
const DISCONNECT_TIMEOUT := 30.0

var _role: String = ""
var _checks: int = 0
var _failures: int = 0
## Host only: the peer id ENet handed the client. Random across the whole
## positive int range, so it is discovered rather than assumed.
var _client_id: int = 0
## Client only: what `user://settings.cfg` said before this run touched it.
var _original_name: Variant = null
var _running: bool = true

# Everything the session did, recorded from signals rather than sampled. A
# frame in this harness can be a whole island build long, which is more than
# enough for a signal to be emitted and answered between two looks at a flag.
var _peer_connected: Array[int] = []
var _peer_disconnected: Array[int] = []
var _joined: bool = false
var _join_failure: String = ""
var _left_lobby: String = ""
## [[sender_id, text], ...]
var _chat: Array = []
## [[victim_id, killer_id, cause], ...]
var _kills: Array = []
## Peers `Net.player_left` named.
var _departed: Array[int] = []
var _config_changes: int = 0
var _match_started: bool = false
## Control-channel messages that have arrived and not been handled yet.
var _inbox: Array[Dictionary] = []


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_role = args[0] if args.size() > 0 else ""

	# Cap the loop to the physics rate, as `tools/snapshot.gd` and
	# `tools/playthrough.gd` do (D-012). Headless has no vsync, so this
	# otherwise free-runs at several thousand frames a second — which a corpse
	# does not survive, and which turns every timeout constant above into a
	# measure of the machine rather than of the game.
	Engine.max_fps = int(ProjectSettings.get_setting(
		"physics/common/physics_ticks_per_second", 60))
	# Step out of the current-scene slot before anything calls
	# `change_scene_to_file`: `SceneTree` frees whatever is in that slot on a
	# scene change, and this node has to outlive the arena it is about to load.
	# It stays a child of `root`, so `/root/NetLoopback` — the path `_ctl`
	# is addressed by — is unchanged.
	get_tree().current_scene = null

	multiplayer.peer_connected.connect(func(id: int) -> void: _peer_connected.append(id))
	multiplayer.peer_disconnected.connect(func(id: int) -> void: _peer_disconnected.append(id))
	Net.joined_lobby.connect(func() -> void: _joined = true)
	Net.join_failed.connect(func(message: String) -> void: _join_failure = message)
	Net.left_lobby.connect(func(_reason: int, message: String) -> void: _left_lobby = message)
	Net.chat_received.connect(func(id: int, text: String) -> void: _chat.append([id, text]))
	Net.player_left.connect(func(id: int) -> void: _departed.append(id))
	Net.config_changed.connect(func() -> void: _config_changes += 1)
	Net.match_start_requested.connect(_on_match_start)
	MatchState.player_killed.connect(
		func(victim: int, killer: int, cause: int) -> void:
			_kills.append([victim, killer, cause]))

	match _role:
		"host":
			await _run_host()
		"join":
			await _run_client(args[1] if args.size() > 1 else "")
		_:
			print("net_loopback: FAIL — no role. Pass `-- host` or `-- join CODE`.")
			get_tree().quit(2)


## What `lobby.gd::_on_match_start` does, and the only reason it is repeated
## here: this harness is not running the lobby scene, so nobody else would take
## the session to the arena.
func _on_match_start() -> void:
	_match_started = true
	await SceneFlow.go_to_arena()


# -------------------------------------------------------------------- host ---

func _run_host() -> void:
	print("net_loopback: role=host pid=%d" % OS.get_process_id())

	if not _require("the port opened", Net.host_lobby()):
		print("net_loopback: %s" % _join_failure)
		await _finish()
		return
	_check("the host is in a session", Net.in_session, true)
	_check("the host is the host", Net.is_host, true)
	_check("the host is not offline", Net.is_offline, false)
	_check("the host is peer 1", Net.local_id(), 1)

	# See HOST_NAME: named in place rather than through `Settings`, which both
	# processes share.
	Net.players[1]["name"] = HOST_NAME
	Net.roster_changed.emit()

	var code := InviteCode.encode(LOOPBACK_IP, Net.hosting_port())
	# The line `tools/net_test.sh` polls for. Everything else can move.
	print("net_loopback: code=%s" % code)
	print("net_loopback: lan_code=%s  (Net.lan_invite_code(), for a real player)"
		% Net.lan_invite_code())
	print("net_loopback: listening on %s:%d" % [LOOPBACK_IP, Net.hosting_port()])

	var ok := await _stage_connect()
	if ok:
		ok = await _stage_roster()
	if ok:
		ok = await _stage_names()
	if ok:
		ok = await _stage_config()
	if ok:
		ok = await _stage_chat()
	if ok:
		ok = await _stage_match_start()
	if ok:
		ok = await _stage_kill()
	# Runs whatever happened above. The client is a live process that has to be
	# told to stop, its tally has to reach this log, and the disconnect is the
	# last check either way.
	await _stage_disconnect()
	await _finish()


## 1/8. A client connects, and both sides notice.
func _stage_connect() -> bool:
	print("net_loopback: stage 1/8 — connection")
	if not await _await_until("a peer to connect", JOIN_TIMEOUT,
			func() -> bool: return not _peer_connected.is_empty()):
		return false
	_client_id = _peer_connected[0]
	_check("exactly one peer connected", _peer_connected.size(), 1)
	_check("the client is not peer 1", _client_id != 1, true)
	# `_on_peer_connected` deliberately does *not* add the newcomer to the
	# roster — it waits to be told a name — so this is the gap between the
	# socket being up and the player existing.
	if not await _await_until("the client to introduce itself", JOIN_TIMEOUT,
			func() -> bool: return Net.has_player(_client_id)):
		return false
	print("net_loopback:   peer %d connected and joined" % _client_id)
	return true


## 2/8. Both sides hold the same roster, and the name got there through
## `_request_join`.
##
## The client's copy is fetched over the control channel, which is this
## harness's own `@rpc` rather than the game's chat — if it were chat, a broken
## chat would look like a broken roster here and the real check would never run.
func _stage_roster() -> bool:
	print("net_loopback: stage 2/8 — roster replication")
	_check("the roster has two players", Net.player_count(), 2)
	var mine := _roster_digest()
	var reply := await _request("roster", {}, STEP_TIMEOUT)
	if reply.is_empty():
		return false
	var theirs: Array = reply.get("digest", [])
	_check("both sides hold the same roster",
		JSON.stringify(theirs), JSON.stringify(mine))
	print("net_loopback:   roster %s" % JSON.stringify(mine))
	return true


## 3/8. The client asked for a name the host already had, and `_unique_name`
## disambiguated it — on the host, where the decision belongs, and on the
## client, which only ever sees the answer.
func _stage_names() -> bool:
	print("net_loopback: stage 3/8 — name collision")
	_check("the host kept its name", Net.player_name(1), HOST_NAME)
	_check("the host renamed the client", Net.player_name(_client_id),
		CLIENT_UNIQUE_NAME)
	var reply := await _request("name", {}, STEP_TIMEOUT)
	if reply.is_empty():
		return false
	_check("the client agrees about its own name", String(reply.get("mine", "")),
		CLIENT_UNIQUE_NAME)
	_check("the client agrees about the host's name",
		String(reply.get("host", "")), HOST_NAME)
	print("net_loopback:   \"%s\" asked for \"%s\" and became \"%s\"" % [
		CLIENT_NAME, CLIENT_NAME, Net.player_name(_client_id)])
	return true


## 4/8. `MatchConfig.to_dict()` over the wire and `apply_dict` on the far side —
## a flat Dictionary of primitives rather than a Resource, so that receiving one
## never means decoding an object (D-004).
func _stage_config() -> bool:
	print("net_loopback: stage 4/8 — config replication")
	var settings := Net.config.duplicate_config()
	settings.map_seed = CONFIG_SEED
	settings.kill_limit = CONFIG_KILL_LIMIT
	settings.lure_radius = CONFIG_LURE_RADIUS
	settings.spear_recharge = CONFIG_SPEAR_RECHARGE
	settings.friendly_fire = true
	settings.warmup_time = WARMUP_TIME
	settings.spawn_protection = SPAWN_PROTECTION
	# The host-side API the lobby's settings panel uses, not a poke at
	# `Net.config`: it re-clamps on the way in and broadcasts on the way out.
	Net.update_config(settings)
	_check("the host took the new seed", Net.config.map_seed, CONFIG_SEED)

	var mine := Net.config.to_dict()
	var reply := await _request("config", {"want": mine}, STEP_TIMEOUT)
	if reply.is_empty():
		return false
	_check("the client holds an identical config",
		JSON.stringify(reply.get("config", {})), JSON.stringify(mine))
	_check("the client was told the config changed",
		int(reply.get("changes", 0)) > 0, true)
	print("net_loopback:   seed %d, kill limit %d, lure radius %s all arrived" % [
		CONFIG_SEED, CONFIG_KILL_LIMIT, str(CONFIG_LURE_RADIUS)])
	return true


## 5/8. Chat in both directions, through `Net.send_chat`, asserting the text and
## who it says sent it.
func _stage_chat() -> bool:
	print("net_loopback: stage 5/8 — chat both directions")
	var before := _chat.size()
	if (await _request("say", {"text": CLIENT_CHAT}, STEP_TIMEOUT)).is_empty():
		return false
	if not await _await_until("the client's chat line", STEP_TIMEOUT,
			func() -> bool: return _chat.size() > before):
		return false
	var line: Array = _chat[before]
	_check("the host heard the client's line", String(line[1]), CLIENT_CHAT)
	_check("the host knows who said it", int(line[0]), _client_id)

	before = _chat.size()
	Net.send_chat(HOST_CHAT)
	# The host's own line comes back through `_submit_chat`'s local call, which
	# is the same code path a remote line takes minus the socket.
	if not await _await_until("the host's own line", STEP_TIMEOUT,
			func() -> bool: return _chat.size() > before):
		return false
	_check("the host hears itself as peer 1", int((_chat[before] as Array)[0]), 1)

	var reply := await _request("heard", {"text": HOST_CHAT}, STEP_TIMEOUT)
	if reply.is_empty():
		return false
	_check("the client heard the host's line", String(reply.get("text", "")), HOST_CHAT)
	_check("the client knows who said it", int(reply.get("from", 0)), 1)
	print("net_loopback:   both directions delivered with the right sender")
	return true


## 6/8. Ready up, then start. `can_start_match()` refuses until every non-host
## peer has readied, so the client's `_request_ready` has to have arrived for
## this to be reachable at all.
func _stage_match_start() -> bool:
	print("net_loopback: stage 6/8 — match start")
	_check("the host cannot start yet", Net.can_start_match(), false)
	if (await _request("ready", {}, STEP_TIMEOUT)).is_empty():
		return false
	if not await _await_until("the client's ready flag", STEP_TIMEOUT,
			func() -> bool: return Net.is_ready(_client_id)):
		return false
	if not _require("the host may start now", Net.can_start_match()):
		return false

	Net.request_match_start()
	_check("the host believes a match is running", Net.match_running, true)
	_check("the host saw match_start_requested", _match_started, true)
	var reply := await _request("started", {}, PHASE_TIMEOUT)
	if reply.is_empty():
		return false
	_check("the client saw match_start_requested", bool(reply.get("started", false)), true)
	_check("the client believes a match is running", bool(reply.get("running", false)), true)
	print("net_loopback:   both peers are in a running match")
	return true


## 7/8. The one that matters. Both peers build the real arena from the
## replicated seed, the host decides a death through `MatchState.report_kill` —
## the same call a landed spear makes — and the client is asked what it saw.
##
## The sub-check about the client's Gubs is not decoration. `_create_gub` is
## dropped on the floor by any peer whose `_players_root` is still null, and the
## host sends it the instant *its own* island finishes. See the note in
## `_stage_kill`'s body for how close that actually runs.
func _stage_kill() -> bool:
	print("net_loopback: stage 7/8 — a kill over the wire")
	var started := Time.get_ticks_msec()
	if not await _await_until("the host's arena", ARENA_TIMEOUT,
			func() -> bool: return get_tree().current_scene is Arena):
		return false
	if not await _await_until("the host reaching PLAYING", PHASE_TIMEOUT,
			func() -> bool: return MatchState.phase == MatchState.Phase.PLAYING):
		return false
	print("net_loopback:   host arena up after %.1f s, %d gubs" % [
		float(Time.get_ticks_msec() - started) * 0.001, MatchState.gubs.size()])
	_check("the host spawned a Gub per player", MatchState.gubs.size(),
		Net.player_count())

	var arena := await _request("arena", {}, ARENA_TIMEOUT)
	if arena.is_empty():
		return false
	_check("the client built the arena too", bool(arena.get("arena", false)), true)
	_check("the client reached PLAYING", int(arena.get("phase", -1)),
		MatchState.Phase.PLAYING)
	_check("the client built the same island from the replicated seed",
		int(arena.get("seed", 0)), CONFIG_SEED)
	# The race, and it is worth knowing exactly how narrow it is, because the
	# code looks far more dangerous than it measures.
	#
	# `MatchState._begin_warmup` runs the moment the *host's* `register_arena`
	# lands and immediately `_create_gub.rpc`s every player. A peer whose
	# `_players_root` is still null drops that on the floor, permanently —
	# nothing re-sends it, and `_do_respawn` also returns early on a Gub that
	# does not exist, so a client that misses the spawn spends the whole match
	# with an empty arena including its own body.
	#
	# What saves it is that the client's island build is one *blocking* call:
	# `change_scene_to_file` does not return until `arena.gd::_ready` has
	# finished, and `_ready` ends by calling `register_arena` itself. No network
	# polling happens anywhere in there, so the queued `_create_gub` packets are
	# not read until after `_players_root` is set. The only losing window is the
	# stretch before the client has *started* its build — `SceneFlow.go_to`
	# fades for 0.22 s and waits two frames on the loading card first — against
	# the host's entire island build, which is 2-6 s. On this machine the client
	# won by that whole margin, every run.
	#
	# So: not a coin flip, but not guarded either. A host with a warm cache and
	# a fast disk against a client that stalls for a quarter of a second on the
	# fade is all it would take, and the failure is silent and total.
	_check("the client has a Gub for every player", int(arena.get("gubs", -1)),
		Net.player_count())

	var victim_gub: Gub = MatchState.gubs.get(_client_id)
	var point := victim_gub.global_position if is_instance_valid(victim_gub) else Vector3.ZERO
	# A blow with real speed in it: the corpse's flight is scaled by it, so a
	# unit vector would leave the ragdoll path exercised but never pushed.
	MatchState.report_kill(_client_id, 1, Gub.Cause.SPEAR, point,
		Vector3.FORWARD * 18.0, "spine.002")
	_check("the host scored the kill", MatchState.kills(1), 1)
	_check("the host recorded the death", MatchState.deaths(_client_id), 1)
	_check("the host's own player_killed fired", _kills.size(), 1)

	var seen := await _request("kill", {"victim": _client_id}, STEP_TIMEOUT)
	if seen.is_empty():
		return false
	_check("the client saw a death", int(seen.get("count", 0)), 1)
	_check("the client agrees who died", int(seen.get("victim", 0)), _client_id)
	_check("the client agrees who killed them", int(seen.get("killer", 0)), 1)
	_check("the client agrees how", int(seen.get("cause", -1)), int(Gub.Cause.SPEAR))
	_check("the client's scores agree", int(seen.get("kills_1", -1)), 1)
	_check("the client's deaths agree", int(seen.get("deaths_victim", -1)), 1)
	print("net_loopback:   kill replicated: %d killed %d, both sides agree" % [
		1, _client_id])
	return true


## 8/8. The client goes away and the host clears up after it. `Net.player_left`
## and `MatchState._on_player_left` are the newest code in the networking layer
## and have never run against a socket.
func _stage_disconnect() -> void:
	if _client_id == 0 or not Net.has_player(_client_id):
		print("net_loopback: stage 8/8 — skipped, no client to disconnect")
		return
	print("net_loopback: stage 8/8 — disconnect")

	# Its tally first, while it can still answer.
	var tally := await _request("finish", {}, STEP_TIMEOUT)
	if tally.is_empty():
		print("net_loopback:   the client never reported its tally")
	else:
		var client_failures := int(tally.get("failures", 0))
		print("net_loopback:   client reported %d checks, %d failures" % [
			int(tally.get("checks", 0)), client_failures])
		_checks += int(tally.get("checks", 0))
		_failures += client_failures

	# Told to leave rather than killed. A hard kill would leave the host to find
	# out through ENet's peer timeout, which is 5-30 s and would make this the
	# slowest and flakiest check in the file; `Net.leave_lobby` closes the peer,
	# which is what the lobby's own Leave button does.
	_ctl.rpc_id(_client_id, "do:leave", {})

	if not await _await_until("peer_disconnected", DISCONNECT_TIMEOUT,
			func() -> bool: return _peer_disconnected.has(_client_id)):
		return
	if not await _await_until("the roster to shrink", STEP_TIMEOUT,
			func() -> bool: return not Net.has_player(_client_id)):
		return
	_check("the roster is down to the host", Net.player_count(), 1)
	_check("Net.player_left named the departed", _departed.has(_client_id), true)
	_check("MatchState dropped their scoring row",
		MatchState.stats.has(_client_id), false)
	_check("MatchState took their Gub out of the world",
		MatchState.gubs.has(_client_id), false)
	print("net_loopback:   peer %d gone, roster %s" % [
		_client_id, JSON.stringify(_roster_digest())])


# ------------------------------------------------------------------ client ---

func _run_client(code: String) -> void:
	print("net_loopback: role=client pid=%d code=%s" % [OS.get_process_id(), code])
	if not _require("a code was passed", not code.is_empty()):
		await _finish()
		return

	# Both processes share `user://settings.cfg` — Godot keys user data on the
	# project name, not the path — and `_on_connected_to_server` sends whatever
	# is in it as the join name. So it is set here, before dialling, which is
	# the only public way to make `_request_join` carry a known string. It is
	# put back in `_finish`. The host does not write this file at all (it names
	# itself in `Net.players` directly), so there is exactly one writer and no
	# race. A run killed between these two points leaves the name as
	# CLIENT_NAME; retype it in Settings if you care.
	_original_name = Settings.get_value("player_name")
	Settings.set_value("player_name", CLIENT_NAME)

	if not _require("the code dialled", Net.join_lobby(code)):
		print("net_loopback: %s" % _join_failure)
		await _finish()
		return
	if not await _await_until("joined_lobby", JOIN_TIMEOUT,
			func() -> bool: return _joined or not _join_failure.is_empty()):
		await _finish()
		return
	if not _require("the join was not refused", _join_failure.is_empty()):
		print("net_loopback: %s" % _join_failure)
		await _finish()
		return

	_check("the client is in a session", Net.in_session, true)
	_check("the client is not the host", Net.is_host, false)
	_check("the client is not peer 1", Net.local_id() != 1, true)
	_check("the client received a roster", Net.player_count(), 2)
	print("net_loopback: joined as peer %d, named \"%s\"" % [
		Net.local_id(), Net.player_name(Net.local_id())])

	# From here the host drives. Every request is a step it wants checked;
	# answering it is how the two logs stay in step.
	while _running:
		var message := await _take_any(STEP_TIMEOUT)
		if message.is_empty():
			_fail("the host went quiet")
			break
		await _serve(message)
	await _finish()


func _serve(message: Dictionary) -> void:
	var topic := String(message["topic"]).trim_prefix("do:")
	var payload: Dictionary = message["payload"]
	var reply := {"ok": true}

	match topic:
		"roster":
			reply["digest"] = _roster_digest()
		"name":
			var mine := Net.player_name(Net.local_id())
			_check("the client was renamed to avoid the host", mine, CLIENT_UNIQUE_NAME)
			_check("the host's name arrived intact", Net.player_name(1), HOST_NAME)
			reply["mine"] = mine
			reply["host"] = Net.player_name(1)
		"config":
			var want: Dictionary = payload.get("want", {})
			var got := Net.config.to_dict()
			_check("the config arrived byte for byte",
				JSON.stringify(got), JSON.stringify(want))
			_check("the seed survived as a 64-bit int", Net.config.map_seed, CONFIG_SEED)
			_check("a float that needs 64 bits survived",
				Net.config.lure_radius, CONFIG_LURE_RADIUS)
			_check("config_changed was emitted", _config_changes > 0, true)
			reply["config"] = got
			reply["changes"] = _config_changes
		"say":
			Net.send_chat(String(payload.get("text", "")))
		"heard":
			var want := String(payload.get("text", ""))
			# Reliable RPCs arrive in order, so the line is almost certainly
			# already here; waiting rather than assuming keeps a slow frame from
			# reading as a lost message.
			await _await_until("the host's chat line", STEP_TIMEOUT,
				func() -> bool: return _last_chat_from(1, want) >= 0)
			var at := _last_chat_from(1, want)
			_check("the host's line arrived", at >= 0, true)
			if at >= 0:
				reply["from"] = int((_chat[at] as Array)[0])
				reply["text"] = String((_chat[at] as Array)[1])
		"ready":
			Net.set_ready(true)
		"started":
			await _await_until("match_start_requested", PHASE_TIMEOUT,
				func() -> bool: return _match_started)
			_check("the client was told to start", _match_started, true)
			_check("match_running reached the client", Net.match_running, true)
			reply["started"] = _match_started
			reply["running"] = Net.match_running
		"arena":
			await _await_until("the client's arena", ARENA_TIMEOUT,
				func() -> bool: return get_tree().current_scene is Arena)
			await _await_until("the client reaching PLAYING", PHASE_TIMEOUT,
				func() -> bool: return MatchState.phase == MatchState.Phase.PLAYING)
			var arena := get_tree().current_scene as Arena
			_check("the client built the arena", arena != null, true)
			_check("phase PLAYING arrived over the wire", MatchState.phase,
				MatchState.Phase.PLAYING)
			_check("the client has a Gub for every player",
				MatchState.gubs.size(), Net.player_count())
			reply["arena"] = arena != null
			reply["phase"] = int(MatchState.phase)
			reply["seed"] = Net.config.map_seed
			reply["gubs"] = MatchState.gubs.size()
			reply["spawns"] = arena.spawn_points.size() if arena != null else 0
		"kill":
			var victim := int(payload.get("victim", 0))
			await _await_until("a death to arrive", STEP_TIMEOUT,
				func() -> bool: return not _kills.is_empty())
			_check("player_killed fired on the client", _kills.size(), 1)
			_check("the client's scoreboard credited the host",
				MatchState.kills(1), 1)
			_check("the client's scoreboard recorded the death",
				MatchState.deaths(victim), 1)
			reply["count"] = _kills.size()
			reply["kills_1"] = MatchState.kills(1)
			reply["deaths_victim"] = MatchState.deaths(victim)
			if not _kills.is_empty():
				var kill: Array = _kills[0]
				reply["victim"] = int(kill[0])
				reply["killer"] = int(kill[1])
				reply["cause"] = int(kill[2])
		"finish":
			reply["checks"] = _checks
			reply["failures"] = _failures
		"leave":
			# The host is watching the socket for this, so there is nothing to
			# reply to. Tidy up first: `Net.leave_lobby` nulls the multiplayer
			# peer, and any Gub still in the tree then asks a session that no
			# longer exists whether it belongs to it, once per frame each.
			MatchState.reset()
			await get_tree().process_frame
			Net.leave_lobby(Net.Leave.LOCAL_REQUEST, "", false)
			_running = false
			return
		_:
			_fail("the host asked for \"%s\", which this harness does not know" % topic)

	_ctl.rpc_id(1, "done:" + topic, reply)


# --------------------------------------------------------- control channel ---

## The harness talking to itself across the socket.
##
## Both processes load `tools/net_loopback.tscn`, so this node is
## `/root/NetLoopback` on both and Godot's RPC addressing resolves it without
## any registration. Keeping the coordination off `Net.send_chat` means the chat
## check in stage 5 is proving the game rather than the scaffolding.
@rpc("any_peer", "call_remote", "reliable")
func _ctl(topic: String, payload: Dictionary) -> void:
	_inbox.append({
		"topic": topic,
		"payload": payload,
		"from": multiplayer.get_remote_sender_id(),
	})


## Host side: ask the client for something and wait for its answer.
func _request(name: String, payload: Dictionary, timeout: float) -> Dictionary:
	if _client_id == 0:
		return {}
	_ctl.rpc_id(_client_id, "do:" + name, payload)
	var message := await _take("done:" + name, timeout)
	if message.is_empty():
		_fail("the client never answered \"%s\" (waited %.0f s)" % [name, timeout])
		return {}
	return message["payload"]


func _take(topic: String, timeout: float) -> Dictionary:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while true:
		for i in _inbox.size():
			if String(_inbox[i]["topic"]) == topic:
				return _inbox.pop_at(i)
		if Time.get_ticks_msec() > deadline:
			return {}
		await get_tree().process_frame
	return {}


func _take_any(timeout: float) -> Dictionary:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while _inbox.is_empty():
		if Time.get_ticks_msec() > deadline:
			return {}
		await get_tree().process_frame
	return _inbox.pop_front()


# ----------------------------------------------------------------- harness ---

## The roster as something two processes can compare with a string equality:
## sorted, and carrying everything `_sync_roster` is supposed to have moved.
func _roster_digest() -> Array:
	var out: Array = []
	for peer_id: int in Net.peer_ids():
		out.append([peer_id, Net.player_name(peer_id), Net.player_team(peer_id),
			Net.is_ready(peer_id)])
	return out


## Index of the most recent chat line from `sender` saying `text`, or -1.
func _last_chat_from(sender: int, text: String) -> int:
	for i in range(_chat.size() - 1, -1, -1):
		var line: Array = _chat[i]
		if int(line[0]) == sender and String(line[1]) == text:
			return i
	return -1


func _check(what: String, got: Variant, want: Variant) -> void:
	_checks += 1
	if got == want:
		return
	_failures += 1
	print("  FAIL  %s: got %s, wanted %s" % [what, str(got), str(want)])


## A check the rest of the run depends on. Same accounting; the caller stops.
func _require(what: String, ok: bool) -> bool:
	_check(what, ok, true)
	return ok


## A failure with no comparison behind it.
func _fail(why: String) -> void:
	_checks += 1
	_failures += 1
	print("  FAIL  %s" % why)


## Spin frames until `ready` says yes. Wall clock rather than a frame count: an
## island build is one blocking frame of unknown length, so counting frames here
## would be counting the wrong thing entirely (D-012 makes the same point about
## the snapshot tool's warmup).
func _await_until(what: String, timeout: float, ready: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while not bool(ready.call()):
		if Time.get_ticks_msec() > deadline:
			_fail("timed out after %.0f s waiting for %s" % [timeout, what])
			return false
		await get_tree().process_frame
	return true


## Print the verdict, put the shared settings file back, and go.
##
## The session is deliberately left open on the host: `Net.leave_lobby` nulls
## the multiplayer peer and every Gub still in the tree then calls
## `multiplayer.get_unique_id()` from `Gub.is_local()` on every frame, which
## buries the verdict under engine errors. Quitting is enough — the engine frees
## the tree and closes the socket on the way out. `tools/playthrough.gd` carries
## the same note.
func _finish() -> void:
	if _original_name != null:
		Settings.set_value("player_name", _original_name)
	MatchState.reset()
	for i in 4:
		await get_tree().process_frame
	print("net_loopback: %d checks, %d failures" % [_checks, _failures])
	print("net_loopback: %s" % ("PASS" if _failures == 0 else "FAIL"))
	get_tree().quit(1 if _failures > 0 else 0)
