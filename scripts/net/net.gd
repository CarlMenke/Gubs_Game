extends Node
## Transport, roster and chat. Autoloaded as `Net`.
##
## Shape of the session (see docs/DECISIONS.md D-004): the host is peer 1, runs
## the authoritative match, and also plays. This node owns three things and
## deliberately nothing else:
##
##   * the ENet peer and its lifecycle,
##   * the roster — who is here, what they are called, which team they are on,
##   * lobby chat.
##
## Match rules, scoring and spawning live in `MatchState`. Keeping them apart
## means a disconnect during a match is handled in exactly one place, and the
## lobby can be exercised without any match code loaded.
##
## The roster is host-authoritative: clients never mutate it directly, they send
## a request and the host broadcasts the new roster. With a cap of eight players
## the whole roster is a few hundred bytes, so pushing it whole on every change
## is simpler and less bug-prone than diffing it.

const DEFAULT_PORT := 27015
const MAX_NAME_LENGTH := 16
const CHAT_MAX_LENGTH := 160
const CONNECT_TIMEOUT := 8.0

## Reasons a session ended, for the message shown on the way back to the menu.
enum Leave {
	LOCAL_REQUEST,
	HOST_CLOSED,
	CONNECTION_LOST,
	CONNECTION_FAILED,
	LOBBY_FULL,
	MATCH_IN_PROGRESS,
}

signal roster_changed()
## A peer has gone, and whatever they left behind in the world is now orphaned.
## `MatchState` listens for this to clear up their Gub — the roster is this
## node's business, but a body standing in the arena is not.
signal player_left(peer_id: int)
signal joined_lobby()
signal join_failed(message: String)
signal left_lobby(reason: Leave, message: String)
signal chat_received(peer_id: int, text: String)
signal config_changed()
signal match_start_requested()
## The host has ended the match for everyone: back to the lobby, together.
signal return_to_lobby_requested()
## The host wants the same match again, same roster, same settings.
signal rematch_requested()

## peer_id -> {name: String, team: int, ready: bool}
var players: Dictionary = {}
var config: MatchConfig = MatchConfig.new()

var is_host: bool = false
var in_session: bool = false
## True in a solo session with no socket. Everything else about it — authority,
## RPC shape, the roster — is identical to hosting, on purpose.
var is_offline: bool = false
## Set by MatchState; the host refuses new joiners into a running match unless
## they are joining as spectators.
var match_running: bool = false

var _bound_port: int = 0
var _connect_timer: SceneTreeTimer = null


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


# ---------------------------------------------------------------- session ---

func host_lobby(port: int = DEFAULT_PORT) -> bool:
	leave_lobby(Leave.LOCAL_REQUEST, "", false)

	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MatchConfig.MAX_PLAYERS)
	if err != OK:
		join_failed.emit("Could not open port %d (error %d).\nAnother copy of the game may already be hosting." % [port, err])
		return false

	multiplayer.multiplayer_peer = peer
	is_host = true
	in_session = true
	_bound_port = port
	config = MatchConfig.new()

	players = {1: _make_player(Settings.sanitized_player_name(), 0)}
	roster_changed.emit()
	joined_lobby.emit()
	return true


## Start a one-player session that opens no port at all.
##
## `OfflineMultiplayerPeer` reports itself as peer 1 and as the server, so every
## `is_host` branch, every `@rpc` call and every authority check downstream takes
## exactly the path it would take when hosting for real — the `rpc()` half simply
## reaches nobody, and the `rpc()`-then-call-locally pattern used throughout the
## game still delivers the local half. That is the point: the testbeds and any
## future single-player mode exercise the shipping code rather than a parallel
## offline branch that can rot without anyone noticing.
func start_offline() -> void:
	leave_lobby(Leave.LOCAL_REQUEST, "", false)

	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	is_host = true
	in_session = true
	is_offline = true
	_bound_port = 0
	config = MatchConfig.new()

	players = {1: _make_player(Settings.sanitized_player_name(), 0)}
	roster_changed.emit()
	joined_lobby.emit()


func join_lobby(code: String) -> bool:
	var endpoint := InviteCode.decode(code)
	if endpoint.is_empty():
		join_failed.emit("\"%s\" is not a valid invite code." % code.strip_edges())
		return false
	return join_address(endpoint["ip"], endpoint["port"])


func join_address(ip: String, port: int) -> bool:
	leave_lobby(Leave.LOCAL_REQUEST, "", false)

	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port)
	if err != OK:
		join_failed.emit("Could not reach %s:%d (error %d)." % [ip, port, err])
		return false

	multiplayer.multiplayer_peer = peer
	is_host = false
	in_session = true
	players.clear()
	roster_changed.emit()

	# ENet reports an unreachable host by simply never connecting, so put a
	# clock on it rather than leaving the player on a dead "Connecting..." screen.
	_connect_timer = get_tree().create_timer(CONNECT_TIMEOUT)
	_connect_timer.timeout.connect(_on_connect_timeout)
	return true


func leave_lobby(reason: Leave = Leave.LOCAL_REQUEST, message: String = "",
		announce: bool = true) -> void:
	_cancel_connect_timer()
	if multiplayer.multiplayer_peer != null \
			and not multiplayer.multiplayer_peer is OfflineMultiplayerPeer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	var was_in_session := in_session
	is_host = false
	in_session = false
	is_offline = false
	match_running = false
	players.clear()
	roster_changed.emit()
	if announce and was_in_session:
		left_lobby.emit(reason, message)


# ------------------------------------------------------------------ roster ---

func local_id() -> int:
	if multiplayer.multiplayer_peer == null:
		return 0
	return multiplayer.get_unique_id()


func has_player(peer_id: int) -> bool:
	return players.has(peer_id)


func player_name(peer_id: int) -> String:
	var info: Dictionary = players.get(peer_id, {})
	return info.get("name", "Gub")


func player_team(peer_id: int) -> int:
	var info: Dictionary = players.get(peer_id, {})
	return info.get("team", MatchConfig.TEAM_NONE)


func is_ready(peer_id: int) -> bool:
	var info: Dictionary = players.get(peer_id, {})
	return info.get("ready", false)


func peer_ids() -> Array:
	var ids := players.keys()
	ids.sort()
	return ids


func player_count() -> int:
	return players.size()


## True when the host is allowed to press Start.
func can_start_match() -> bool:
	if not is_host or players.size() < MatchConfig.MIN_PLAYERS:
		return false
	for peer_id: int in players:
		if peer_id != 1 and not is_ready(peer_id):
			return false
	if config.mode == MatchConfig.Mode.TEAMS:
		# Every team that exists must have someone on it, or a team wins by
		# default the moment the match starts.
		var occupied := {}
		for peer_id: int in players:
			occupied[player_team(peer_id)] = true
		if occupied.size() < 2:
			return false
	return true


func _make_player(display_name: String, team: int) -> Dictionary:
	return {"name": display_name, "team": team, "ready": false}


## Put the next joiner on whichever team is smallest, so lobbies self-balance.
func _smallest_team() -> int:
	if config.mode != MatchConfig.Mode.TEAMS:
		return 0
	var counts := PackedInt32Array()
	counts.resize(config.team_count)
	counts.fill(0)
	for peer_id: int in players:
		var team := player_team(peer_id)
		if team >= 0 and team < counts.size():
			counts[team] += 1
	var best := 0
	for i in counts.size():
		if counts[i] < counts[best]:
			best = i
	return best


static func sanitize_name(raw: String, fallback: String = "Gub") -> String:
	var text := raw.strip_edges()
	var out := ""
	for c in text:
		# Control characters would let a name break the nameplate or the chat log.
		if c.unicode_at(0) < 32:
			continue
		out += c
		if out.length() >= MAX_NAME_LENGTH:
			break
	out = out.strip_edges()
	return out if not out.is_empty() else fallback


## Names must be distinct or the nameplates above two Gubs become useless.
func _unique_name(desired: String, for_peer: int) -> String:
	var taken := {}
	for peer_id: int in players:
		if peer_id != for_peer:
			taken[player_name(peer_id).to_lower()] = true
	if not taken.has(desired.to_lower()):
		return desired
	for suffix in range(2, 100):
		var tag := " (%d)" % suffix
		var trimmed := desired.substr(0, MAX_NAME_LENGTH - tag.length())
		var candidate := trimmed + tag
		if not taken.has(candidate.to_lower()):
			return candidate
	return desired


# ------------------------------------------------------- signal plumbing ----

func _on_peer_connected(peer_id: int) -> void:
	# The host waits for the newcomer to introduce itself before adding it to
	# the roster; a peer with no name yet would flash as a blank row.
	if not is_host:
		return
	if players.size() >= config.max_players:
		_reject.rpc_id(peer_id, Leave.LOBBY_FULL, "This lobby is full.")
		return
	if match_running:
		_reject.rpc_id(peer_id, Leave.MATCH_IN_PROGRESS,
			"That match has already started.")
		return


func _on_peer_disconnected(peer_id: int) -> void:
	if not is_host:
		return
	if players.erase(peer_id):
		_announce_departure.rpc(peer_id)
		_announce_departure(peer_id)
		_broadcast_roster()
		roster_changed.emit()


## Told to everyone, not just the host, because every peer is carrying its own
## copy of the departed player's Gub. Before this existed a client who alt-F4'd
## mid-match left their Gub standing in the arena on all seven other machines,
## for the rest of the match — a permanently motionless target that could still
## be thrown at and still counted toward "last Gub standing".
@rpc("authority", "call_remote", "reliable")
func _announce_departure(peer_id: int) -> void:
	player_left.emit(peer_id)


func _on_connected_to_server() -> void:
	_cancel_connect_timer()
	_request_join.rpc_id(1, Settings.sanitized_player_name())


func _on_connection_failed() -> void:
	_cancel_connect_timer()
	leave_lobby(Leave.CONNECTION_FAILED, "", false)
	join_failed.emit("Could not connect. Check the invite code, and that the host has the game open.")


func _on_server_disconnected() -> void:
	leave_lobby(Leave.HOST_CLOSED, "The host closed the lobby.")


func _on_connect_timeout() -> void:
	_connect_timer = null
	if in_session and not is_host and players.is_empty():
		leave_lobby(Leave.CONNECTION_FAILED, "", false)
		join_failed.emit("Timed out reaching the host.\nIf they are not on your network they need port %d forwarded." % DEFAULT_PORT)


func _cancel_connect_timer() -> void:
	if _connect_timer != null and _connect_timer.timeout.is_connected(_on_connect_timeout):
		_connect_timer.timeout.disconnect(_on_connect_timeout)
	_connect_timer = null


# --------------------------------------------------------------- transfer ---

func _broadcast_roster() -> void:
	_sync_roster.rpc(players, config.to_dict())


@rpc("any_peer", "call_remote", "reliable")
func _request_join(desired_name: String) -> void:
	if not is_host:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if players.size() >= config.max_players:
		_reject.rpc_id(peer_id, Leave.LOBBY_FULL, "This lobby is full.")
		return
	var clean := _unique_name(sanitize_name(desired_name), peer_id)
	players[peer_id] = _make_player(clean, _smallest_team())
	_broadcast_roster()
	roster_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _sync_roster(roster: Dictionary, config_data: Dictionary) -> void:
	var was_empty := players.is_empty()
	players = roster
	config.apply_dict(config_data)
	roster_changed.emit()
	config_changed.emit()
	if was_empty and players.has(local_id()):
		joined_lobby.emit()


@rpc("authority", "call_remote", "reliable")
func _reject(reason: Leave, message: String) -> void:
	leave_lobby(reason, "", false)
	join_failed.emit(message)


# ------------------------------------------------------- roster mutations ---

func set_ready(value: bool) -> void:
	_request_ready.rpc_id(1, value)
	if is_host:
		_request_ready(value)


@rpc("any_peer", "call_remote", "reliable")
func _request_ready(value: bool) -> void:
	if not is_host:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if peer_id == 0:
		peer_id = 1  # host calling into itself
	if not players.has(peer_id):
		return
	players[peer_id]["ready"] = bool(value)
	_broadcast_roster()
	roster_changed.emit()


func set_team(team: int) -> void:
	_request_team.rpc_id(1, team)
	if is_host:
		_request_team(team)


@rpc("any_peer", "call_remote", "reliable")
func _request_team(team: int) -> void:
	if not is_host:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if peer_id == 0:
		peer_id = 1
	if not players.has(peer_id) or config.mode != MatchConfig.Mode.TEAMS:
		return
	players[peer_id]["team"] = clampi(int(team), 0, config.team_count - 1)
	_broadcast_roster()
	roster_changed.emit()


func set_name_local(new_name: String) -> void:
	Settings.set_value("player_name", new_name)
	if not in_session:
		return
	_request_rename.rpc_id(1, new_name)
	if is_host:
		_request_rename(new_name)


@rpc("any_peer", "call_remote", "reliable")
func _request_rename(new_name: String) -> void:
	if not is_host:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if peer_id == 0:
		peer_id = 1
	if not players.has(peer_id):
		return
	players[peer_id]["name"] = _unique_name(sanitize_name(new_name), peer_id)
	_broadcast_roster()
	roster_changed.emit()


## Host only. Pushes an edited match configuration to everyone.
func update_config(new_config: MatchConfig) -> void:
	if not is_host:
		return
	config.apply_dict(new_config.to_dict())
	# Changing team count can strand players on a team that no longer exists.
	if config.mode == MatchConfig.Mode.TEAMS:
		for peer_id: int in players:
			var team: int = players[peer_id].get("team", 0)
			if team < 0 or team >= config.team_count:
				players[peer_id]["team"] = _smallest_team()
	_broadcast_roster()
	roster_changed.emit()
	config_changed.emit()


# ------------------------------------------------------------------- chat ---

func send_chat(text: String) -> void:
	var clean := text.strip_edges().substr(0, CHAT_MAX_LENGTH)
	if clean.is_empty():
		return
	_submit_chat.rpc_id(1, clean)
	if is_host:
		_submit_chat(clean)


@rpc("any_peer", "call_remote", "reliable")
func _submit_chat(text: String) -> void:
	if not is_host:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if peer_id == 0:
		peer_id = 1
	if not players.has(peer_id):
		return
	var clean := String(text).strip_edges().substr(0, CHAT_MAX_LENGTH)
	if clean.is_empty():
		return
	_deliver_chat.rpc(peer_id, clean)
	_deliver_chat(peer_id, clean)


@rpc("authority", "call_remote", "reliable")
func _deliver_chat(peer_id: int, text: String) -> void:
	chat_received.emit(peer_id, text)


# ------------------------------------------------------------ match start ---

## Host only. Tells everyone to load the arena.
func request_match_start() -> void:
	if not is_host or not can_start_match():
		return
	_begin_match.rpc()
	_begin_match()


@rpc("authority", "call_remote", "reliable")
func _begin_match() -> void:
	match_running = true
	match_start_requested.emit()


## Host only. Ends the match for everybody and sends the whole lobby home.
##
## Without this the host's "back to the lobby" button moved exactly one person:
## every client stayed sitting on a results screen with no way out but leaving
## the session entirely. A match is a thing the lobby does together, so ending
## one is a broadcast rather than a local navigation.
func request_return_to_lobby() -> void:
	if not is_host:
		return
	match_running = false
	_return_to_lobby.rpc()
	_return_to_lobby()


@rpc("authority", "call_remote", "reliable")
func _return_to_lobby() -> void:
	match_running = false
	return_to_lobby_requested.emit()


## Host only. Run it again — same roster, same settings, same map seed.
##
## The seed is deliberately left alone. "Rematch" is a request for another go at
## the match everyone just agreed to, and quietly handing them a different island
## would be a different request. Rerolling the map is a lobby control.
func request_rematch() -> void:
	if not is_host:
		return
	match_running = true
	_rematch.rpc()
	_rematch()


@rpc("authority", "call_remote", "reliable")
func _rematch() -> void:
	match_running = true
	rematch_requested.emit()


# ------------------------------------------------------------- addressing ---

## The address other players on this network should dial. Prefers a private LAN
## address over anything else, since that is the case that works with no setup.
func local_ipv4() -> String:
	var private: String = ""
	var fallback: String = ""
	for address: String in IP.get_local_addresses():
		if address.count(".") != 3 or address.begins_with("127."):
			continue
		if address.begins_with("192.168.") or address.begins_with("10.") \
				or _is_carrier_private(address):
			if private.is_empty():
				private = address
		elif fallback.is_empty():
			fallback = address
	if not private.is_empty():
		return private
	return fallback if not fallback.is_empty() else "127.0.0.1"


static func _is_carrier_private(address: String) -> bool:
	if not address.begins_with("172."):
		return false
	var second := address.split(".")[1].to_int()
	return second >= 16 and second <= 31


## The invite code to hand to players on the same network.
func lan_invite_code() -> String:
	return InviteCode.encode(local_ipv4(), _bound_port if _bound_port > 0 else DEFAULT_PORT)


func hosting_port() -> int:
	return _bound_port if _bound_port > 0 else DEFAULT_PORT
